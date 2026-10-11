import AppKit
import IndieCore
import IndieRuntime
@preconcurrency import Metal
import MetalFX
@preconcurrency import QuartzCore
import CoreVideo

/// Two queued pairs maximum. Refresh callbacks, not ML completion callbacks,
/// choose the image to display. Source SCStream surfaces never enter this queue.
@MainActor
final class InterpolationMetalPresenter: NSObject, @preconcurrency CAMetalDisplayLinkDelegate {
    struct Snapshot: Codable {
        var presentedOriginal = 0
        var presentedGenerated = 0
        var repeatedRefreshes = 0
        var skipped = 0
        var gpuBusy = 0
        var maximumQueueDepth = 0
        var requestedRefreshRate: Double = 120
        var intervalP95Milliseconds: Double = 0
        var intervalP99Milliseconds: Double = 0
        var predictionLeadMilliseconds: Double = 0
    }
    private struct Frame {
        let id: Int
        let image: InterpolationImage
        let time: Double
        let generated: Bool
    }
    /// Retain IOSurface texture wrappers until the GPU has finished sampling.
    private struct GPUInput: @unchecked Sendable {
        let image: InterpolationImage
        let wrappers: [CVMetalTexture]
    }
    let layer = CAMetalLayer()
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private let convert: MTLComputePipelineState
    private let render: MTLRenderPipelineState
    private let scaler: MTLFXSpatialScaler?
    private let input: MTLTexture
    private let output: MTLTexture?
    private var link: CAMetalDisplayLink?
    private var frames: [Frame] = []
    private var current: Frame?
    private var nextID = 0
    private var running = true
    private let inFlight = DispatchSemaphore(value: 2)
    private var lastPresentedID: Int?
    private var lastPresentedTime: Double?
    private var lastTargetTime: Double?
    private var intervals: [Double] = []
    private var statistics = Snapshot()
    var onFailure: ((String) -> Void)?
    var onStarvation: (() -> Void)?
    var refreshInterval: Double = 1 / 120.0
    var presentationLead: Double = 0
    var snapshot: Snapshot {
        var result = statistics
        let sorted = intervals.sorted()
        if !sorted.isEmpty {
            result.intervalP95Milliseconds = sorted[min(sorted.count-1, Int(Double(sorted.count-1)*0.95))] * 1000
            result.intervalP99Milliseconds = sorted[min(sorted.count-1, Int(Double(sorted.count-1)*0.99))] * 1000
        }
        return result
    }

    init(processing: FrameInterpolationResolution, displayWidth: Int, displayHeight: Int, maximumRefreshRate: Int = 120) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue() else {
            throw Self.failure("Metal unavailable")
        }
        self.device = device; self.commands = commands
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw Self.failure("Metal texture cache unavailable")
        }
        self.cache = cache
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let conversion = library.makeFunction(name: "convert_frame") else { throw Self.failure("Missing conversion shader") }
        convert = try device.makeComputePipelineState(function: conversion)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "frame_vertex")
        desc.fragmentFunction = library.makeFunction(name: "frame_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        render = try device.makeRenderPipelineState(descriptor: desc)

        let upscale = MTLFXSpatialScalerDescriptor()
        upscale.inputWidth = processing.width; upscale.inputHeight = processing.height
        upscale.outputWidth = displayWidth; upscale.outputHeight = displayHeight
        upscale.colorTextureFormat = .bgra8Unorm; upscale.outputTextureFormat = .bgra8Unorm
        upscale.colorProcessingMode = .perceptual
        scaler = displayWidth >= processing.width && displayHeight >= processing.height &&
            (displayWidth > processing.width || displayHeight > processing.height) &&
            MTLFXSpatialScalerDescriptor.supportsDevice(device) ? upscale.makeSpatialScaler(device: device) : nil
        let source = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: processing.width, height: processing.height, mipmapped: false)
        source.storageMode = .private
        source.usage = [.shaderWrite, .shaderRead]
        if let scaler { source.usage.formUnion(scaler.colorTextureUsage) }
        guard let input = device.makeTexture(descriptor: source) else { throw Self.failure("Input texture allocation failed") }
        self.input = input
        if let scaler {
            let dest = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: displayWidth, height: displayHeight, mipmapped: false)
            dest.storageMode = .private; dest.usage = scaler.outputTextureUsage.union(.shaderRead)
            guard let output = device.makeTexture(descriptor: dest) else { throw Self.failure("Output texture allocation failed") }
            self.output = output
        } else { output = nil }
        super.init()
        layer.device = device; layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true; layer.isOpaque = false
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.drawableSize = CGSize(width: displayWidth, height: displayHeight)
        layer.maximumDrawableCount = 3
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        // Keep a full-refresh scheduling clock. A 60 Hz callback request on
        // this ProMotion Mac coalesced generated frames in the local probe.
        // Repeated refreshes reuse the cached upscale without rerunning it.
        let rate = Float(max(30, min(120, maximumRefreshRate)))
        statistics.requestedRefreshRate = Double(rate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.preferredFrameLatency = 1
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    var upscaling: String { scaler == nil ? "linear" : "MetalFX Spatial" }

    func enqueue(generated: InterpolationImage, original: InterpolationImage,
                 schedule: FrameInterpolationPacer.Pair) -> Bool {
        guard running, frames.count <= 2 else { statistics.skipped += 2; return false }
        for (image, time, generated) in [(generated, schedule.generated, true), (original, schedule.original, false)] {
            nextID += 1
            frames.append(Frame(id: nextID, image: image, time: time, generated: generated))
        }
        statistics.maximumQueueDepth = max(statistics.maximumQueueDepth, frames.count)
        link?.isPaused = false
        return true
    }
    func pause() {
        frames.removeAll(); current = nil
        lastPresentedID = nil; lastPresentedTime = nil
        link?.isPaused = true
    }
    func discardQueued() { frames.removeAll() }
    func stop() {
        running = false; pause(); link?.invalidate(); link = nil
        onFailure = nil; onStarvation = nil
        CVMetalTextureCacheFlush(cache, 0)
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard running else { return }
        let now = CACurrentMediaTime()
        let target = update.targetPresentationTimestamp
        presentationLead = max(0, min(0.05, target - now))
        statistics.predictionLeadMilliseconds = presentationLead * 1000
        let observed = lastTargetTime.map { target - $0 } ?? 0
        if observed > 0.002, observed < 0.04 { refreshInterval = observed }
        lastTargetTime = target
        guard inFlight.wait(timeout: .now()) == .success else { statistics.gpuBusy += 1; return }
        let semaphore = inFlight
        guard let command = commands.makeCommandBuffer() else { semaphore.signal(); return }
        var newest: Frame?
        while let first = frames.first, first.time <= target + refreshInterval * 0.15 {
            if newest != nil { statistics.skipped += 1 }
            newest = frames.removeFirst()
        }
        let changed = newest != nil
        if let newest { current = newest }
        guard let frame = current else { semaphore.signal(); return }
        // No stale overlay during capture/inference starvation.
        guard now - frame.time < 0.15 else {
            semaphore.signal(); pause(); onStarvation?(); return
        }
        do {
            var hold: GPUInput?
            if changed {
                hold = try encodeConversion(frame.image, command: command)
                if let scaler, let output {
                    scaler.colorTexture = input; scaler.outputTexture = output
                    scaler.inputContentWidth = input.width; scaler.inputContentHeight = input.height
                    scaler.encode(commandBuffer: command)
                }
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = update.drawable.texture
            pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Self.failure("Render encoder unavailable") }
            encoder.setRenderPipelineState(render)
            encoder.setFragmentTexture(output ?? input, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            let identifier = frame.id, generated = frame.generated
            update.drawable.addPresentedHandler { [weak self] drawable in
                let time = drawable.presentedTime
                Task { @MainActor in self?.recordPresentation(id: identifier, generated: generated, time: time) }
            }
            command.addCompletedHandler { [weak self, hold] command in
                withExtendedLifetime(hold) {}
                semaphore.signal()
                if command.status == .error {
                    let message = command.error?.localizedDescription ?? "GPU presentation failed"
                    Task { @MainActor in self?.onFailure?(message) }
                }
            }
            // CAMetalDisplayLink already schedules this drawable for its
            // target. present(atTime:) is explicitly rejected at runtime.
            command.present(update.drawable)
            command.commit()
        } catch {
            semaphore.signal(); onFailure?(error.localizedDescription)
        }
    }

    private func recordPresentation(id: Int, generated: Bool, time: Double) {
        guard running, time.isFinite, time > 0 else { return }
        guard id != lastPresentedID else { statistics.repeatedRefreshes += 1; return }
        if let previous = lastPresentedTime, time > previous {
            intervals.append(time - previous)
            if intervals.count > 600 { intervals.removeFirst(intervals.count-600) }
        }
        lastPresentedID = id; lastPresentedTime = time
        if generated { statistics.presentedGenerated += 1 } else { statistics.presentedOriginal += 1 }
    }
    private func encodeConversion(_ image: InterpolationImage, command: MTLCommandBuffer) throws -> GPUInput {
        let pixel = image.buffer
        let format = CVPixelBufferGetPixelFormatType(pixel)
        let isBGRA = format == kCVPixelFormatType_32BGRA
        guard isBGRA || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { throw Self.failure("Unsupported SDR interpolation format") }
        var wrappers: [CVMetalTexture] = []
        for plane in 0..<(isBGRA ? 1 : 2) {
            var wrapper: CVMetalTexture?
            let width = isBGRA ? CVPixelBufferGetWidth(pixel) : CVPixelBufferGetWidthOfPlane(pixel, plane)
            let height = isBGRA ? CVPixelBufferGetHeight(pixel) : CVPixelBufferGetHeightOfPlane(pixel, plane)
            let pixelFormat: MTLPixelFormat = isBGRA ? .bgra8Unorm : (plane == 0 ? .r8Unorm : .rg8Unorm)
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixel, nil, pixelFormat,
                width, height, plane, &wrapper) == kCVReturnSuccess, let wrapper else { throw Self.failure("IOSurface texture mapping failed") }
            wrappers.append(wrapper)
        }
        guard let encoder = command.makeComputeCommandEncoder() else { throw Self.failure("Conversion encoder unavailable") }
        encoder.setComputePipelineState(convert)
        encoder.setTexture(CVMetalTextureGetTexture(wrappers[0]), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(wrappers.last!), index: 1)
        encoder.setTexture(input, index: 2)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let matrix = CVBufferCopyAttachment(pixel, kCVImageBufferYCbCrMatrixKey, nil) as? String
        var values = SIMD4<Float>(isBGRA ? 1 : 0, fullRange ? 1 : 0,
                                 matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 1 : 0, 0)
        encoder.setBytes(&values, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: input.width, height: input.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        return GPUInput(image: image, wrappers: wrappers)
    }
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Indie.InterpolationPresentation", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void convert_frame(texture2d<float, access::read> color [[texture(0)]],
                              texture2d<float, access::read> chroma [[texture(1)]],
                              texture2d<float, access::write> output [[texture(2)]],
                              constant float4 &options [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        if (options.x > 0.5) { output.write(float4(color.read(p).rgb, 1.0), p); return; }
        float y = color.read(p).r;
        float2 uv = chroma.read(p/2).rg - float2(128.0/255.0);
        if (options.y < 0.5) { y = (y - 16.0/255.0) * (255.0/219.0); uv *= (255.0/224.0); }
        float3 rgb = options.z > 0.5 ? float3(y+1.402*uv.y, y-0.344136*uv.x-0.714136*uv.y, y+1.772*uv.x)
                                    : float3(y+1.5748*uv.y, y-0.187324*uv.x-0.468124*uv.y, y+1.8556*uv.x);
        output.write(float4(clamp(rgb, 0.0, 1.0), 1.0), p);
    }
    struct Raster { float4 position [[position]]; float2 uv; };
    vertex Raster frame_vertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        Raster out; out.position = float4(uv.x*2-1, 1-uv.y*2, 0, 1); out.uv = uv; return out;
    }
    fragment float4 frame_fragment(Raster in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        return float4(image.sample(linearSampler, in.uv).rgb, 1.0);
    }
    """
}
