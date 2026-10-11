import AppKit
import ScreenCaptureKit
import IndieCore

private final class CaptureCounter: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Snapshot: Codable { let elapsed: Double; let captured: Int; let changing: Int }
    private let lock = NSLock()
    private var captured = 0, changing = 0
    private var previous: [UInt32] = []
    private let started = Date()
    var snapshot: Snapshot { lock.withLock {
        Snapshot(elapsed: Date().timeIntervalSince(started), captured: captured, changing: changing)
    } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixel = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        var values: [UInt32] = []; values.reserveCapacity(32*18)
        for y in 0..<18 { for x in 0..<32 {
            values.append(base.load(fromByteOffset: (y*height/18)*stride + (x*width/32)*4, as: UInt32.self))
        } }
        lock.withLock {
            captured += 1
            if values != previous { changing += 1; previous = values }
        }
    }
}

@main struct InterpolationBaselineProbe {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                func argument(_ key: String) -> String? {
                    guard let index = CommandLine.arguments.firstIndex(of: key), index+1 < CommandLine.arguments.count else { return nil }
                    return CommandLine.arguments[index+1]
                }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let id = argument("--window").flatMap(UInt32.init),
                      let window = content.windows.first(where: { $0.windowID == id }),
                      let owner = window.owningApplication else { print("Target window absent"); exit(1) }
                NSRunningApplication(processIdentifier: owner.processID)?.activate(options: .activateAllWindows)
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard let fit = FrameInterpolationResolution.fitted(width: Int(filter.contentRect.width*Double(filter.pointPixelScale)),
                                                                   height: Int(filter.contentRect.height*Double(filter.pointPixelScale))) else { exit(1) }
                let config = SCStreamConfiguration(); config.width = fit.width; config.height = fit.height
                config.scalesToFit = true; config.preservesAspectRatio = false
                config.pixelFormat = kCVPixelFormatType_32BGRA; config.showsCursor = false
                config.capturesAudio = false; config.captureMicrophone = false
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60); config.queueDepth = 3
                let output = CaptureCounter()
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "baseline.capture"))
                try await stream.startCapture()
                var samples: [CaptureCounter.Snapshot] = []
                for _ in 0..<max(1, Int(argument("--duration") ?? "20") ?? 20) {
                    try await Task.sleep(for: .seconds(1)); samples.append(output.snapshot)
                }
                try await stream.stopCapture()
                if let path = argument("--output") {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(samples).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                print("Sampled changing images, not engine FPS: \(output.snapshot)")
                exit(output.snapshot.captured > 0 ? 0 : 2)
            } catch { print(error); exit(3) }
        }
        app.run()
    }
}
