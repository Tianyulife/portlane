import AppKit
import Combine
import Carbon
import QuartzCore
import IndieCore
import IndieRuntime
@preconcurrency import ScreenCaptureKit
@preconcurrency import VideoToolbox

private final class InterpolationCaptureSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let continuation: AsyncStream<InterpolationImage>.Continuation
    private let lock = NSLock()
    private var count = 0
    private var copyFailures = 0
    // Never retain ScreenCaptureKit's limited IOSurfaces in the presentation
    // queue. Copy to our own bounded pool and release the capture buffer now.
    private var ownedPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    var capturedCount: Int { lock.withLock { count } }
    var failedCopyCount: Int { lock.withLock { copyFailures } }
    init(_ continuation: AsyncStream<InterpolationImage>.Continuation) { self.continuation = continuation }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let values = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = values.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = sample.imageBuffer else { return }
        lock.withLock { count += 1 }
        if ownedPool == nil {
            let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: CVPixelBufferGetWidth(image),
                kCVPixelBufferHeightKey as String: CVPixelBufferGetHeight(image),
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &ownedPool)
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        }
        guard let ownedPool, let transfer else { return }
        var copy: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 8] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, ownedPool, limit, &copy) == kCVReturnSuccess,
              let copy, VTPixelTransferSessionTransferImage(transfer, from: image, to: copy) == noErr else {
            lock.withLock { copyFailures += 1 }
            return
        }
        continuation.yield(InterpolationImage(buffer: copy, timestamp: sample.presentationTimeStamp))
    }
    deinit { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }
}

private func interpolationEmergencyStop(_ next: EventHandlerCallRef?, _ event: EventRef?, _ data: UnsafeMutableRawPointer?) -> OSStatus {
    if #available(macOS 26, *) { Task { @MainActor in GameFrameInterpolation.shared.stop() } }
    return noErr
}

private final class PassthroughFrameWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@available(macOS 26, *)
@MainActor
final class GameFrameInterpolation: ObservableObject {
    /// Developer telemetry separates capture starvation from ML cost and presentation drops.
    /// None of these counters claims a physical display FPS measurement.
    struct DiagnosticSnapshot: Codable {
        struct WindowObservation: Codable {
            let windowID: UInt32
            let ownerPID: Int32
            let foregroundPID: Int32?
            let onScreen: Bool?
            let width: Double?
            let height: Double?
            let expectedWidth: Double
            let expectedHeight: Double
            let layer: Int?
        }
        let elapsedSeconds: Double
        let captured: Int
        let captureCopyFailures: Int
        let received: Int
        let generated: Int
        let submitted: Int
        let dropped: Int
        let backpressure: Int
        let processingWidth: Int
        let processingHeight: Int
        let displayWidth: Int
        let displayHeight: Int
        let processingP95Milliseconds: Double
        let deadlineDrops: Int
        let presentation: InterpolationMetalPresenter.Snapshot
        var active: Bool
        var status: String
        var stopKind: String?
        let visibilitySuspensions: Int
        let visibilityRecoveries: Int
        let windowObservation: WindowObservation?
        let overlayWindowID: Int?
        let overlayVisible: Bool
        let overlayOnScreen: Bool?
        let overlayOcclusionVisible: Bool
        let overlayLevel: Int?
        let overlayWidth: Double?
        let overlayHeight: Double?
        let overlayX: Double?
        let overlayY: Double?
    }
    var diagnostics: DiagnosticSnapshot {
        if !active, let terminalDiagnostics { return terminalDiagnostics }
        let costs = processingCosts.sorted()
        let overlayInfo = overlay.flatMap {
            (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID($0.windowNumber)) as? [[String: Any]])?.first
        }
        return DiagnosticSnapshot(elapsedSeconds: Date().timeIntervalSince(began), captured: sink?.capturedCount ?? 0,
                           captureCopyFailures: sink?.failedCopyCount ?? 0,
                           received: received, generated: processed, submitted: submitted,
                           dropped: dropped, backpressure: rendererBackpressure,
                           processingWidth: processingResolution?.width ?? 0, processingHeight: processingResolution?.height ?? 0,
                           displayWidth: displayWidth, displayHeight: displayHeight,
                           processingP95Milliseconds: costs.isEmpty ? 0 : costs[min(costs.count-1, Int(Double(costs.count-1)*0.95))] * 1000,
                           deadlineDrops: deadlineDrops, presentation: presenter?.snapshot ?? .init(), active: active,
                           status: status, stopKind: nil, visibilitySuspensions: visibilitySuspensions,
                           visibilityRecoveries: visibilityRecoveries, windowObservation: windowObservation,
                           overlayWindowID: overlay?.windowNumber, overlayVisible: overlay?.isVisible == true,
                           overlayOnScreen: overlayInfo?[kCGWindowIsOnscreen as String] as? Bool,
                           overlayOcclusionVisible: overlay?.occlusionState.contains(.visible) == true,
                           overlayLevel: overlay?.level.rawValue,
                           overlayWidth: overlay.map { Double($0.frame.width) }, overlayHeight: overlay.map { Double($0.frame.height) },
                           overlayX: overlay.map { Double($0.frame.minX) }, overlayY: overlay.map { Double($0.frame.minY) })
    }
    enum StopKind { case manual, transient, failure, replaced }
    var onStopped: ((StopKind) -> Void)?
    static let shared = GameFrameInterpolation()
    @Published private(set) var active = false
    @Published private(set) var status = L("插帧已关闭")
    @Published private(set) var metrics = ""
    @Published private(set) var windows: [SCWindow] = []
    private var stream: SCStream?
    private var sink: InterpolationCaptureSink?
    private var engine: FrameInterpolationEngine?
    private var worker: Task<Void, Never>?
    private var watchdog: Timer?
    private var overlay: NSWindow?
    private var presenter: InterpolationMetalPresenter?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var generation = UUID()
    private var target: SCWindow?
    private var began = Date()
    private var lastProgress = Date()
    private var lastMetricUpdate = Date.distantPast
    private var hasOutput = false
    private var processed = 0
    private var submitted = 0
    private var dropped = 0
    private var received = 0
    private var rendererBackpressure = 0
    private var pacer = FrameInterpolationPacer()
    private var processingResolution: FrameInterpolationResolution?
    private var displayWidth = 0
    private var displayHeight = 0
    private var processingCosts: [Double] = []
    private var deadlineDrops = 0
    private var consecutiveOverruns = 0
    private var cooldownUntil = Date.distantPast
    private let analyzer = InterpolationFrameAnalyzer()
    private var displayTopology = ""
    private var processingInFlight = false
    private var processingStartedAt: Double = 0
    private var visibilityGate = FrameInterpolationVisibilityGate()
    private var visibilitySuspensions = 0
    private var visibilityRecoveries = 0
    private var windowObservation: DiagnosticSnapshot.WindowObservation?
    private var terminalDiagnostics: DiagnosticSnapshot?
    private var presentationHealth = FrameInterpolationPresentationHealth()

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), interpolationEmergencyStop, 1, &eventType, nil, &handler)
        let keyID = EventHotKeyID(signature: 0x4D475546, id: 1)
        RegisterEventHotKey(UInt32(kVK_F12), UInt32(cmdKey | optionKey | controlKey), keyID,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    func refreshWindows() async {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            status = L("请在系统设置中允许屏幕录制，然后重新打开应用。无需麦克风权限。")
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            windows = content.windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                FrameInterpolationWindowLayer.isEligible($0.windowLayer) &&
                $0.frame.width >= 320 && $0.frame.height >= 200 && !($0.title ?? "").isEmpty
            }.sorted { ($0.title ?? "") < ($1.title ?? "") }
        } catch { status = error.localizedDescription }
    }

    func start(windowID: CGWindowID, automatically: Bool = false, expectedPID: Int32? = nil) async {
        stop(kind: .replaced)
        terminalDiagnostics = nil
        guard hotKey != nil else { status = L("无法注册紧急停止快捷键，插帧未启动"); return }
        guard FrameInterpolationEngine.isSupported else { status = L("此设备不支持 VideoToolbox 插帧"); return }
        guard CGPreflightScreenCaptureAccess() else {
            if !automatically { await refreshWindows() }
            return
        }
        let token = generation
        active = true
        status = L("正在准备插帧；原游戏画面保持可见…")
        began = Date(); lastProgress = began
        displayTopology = topology()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLifetime() }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard token == generation else { return }
            guard let window = content.windows.first(where: { $0.windowID == windowID }),
                  let owner = window.owningApplication,
                  owner.processID != ProcessInfo.processInfo.processIdentifier,
                  expectedPID == nil || expectedPID == owner.processID else {
                throw failure(L("游戏窗口已关闭，请重新选择"))
            }
            target = window
            if !automatically { NSRunningApplication(processIdentifier: owner.processID)?.activate(options: .activateAllWindows) }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            displayWidth = Int((filter.contentRect.width * Double(filter.pointPixelScale)).rounded())
            displayHeight = Int((filter.contentRect.height * Double(filter.pointPixelScale)).rounded())
            guard displayWidth > 0, displayHeight > 0,
                  abs(Double(displayWidth) / Double(displayHeight) - window.frame.width / window.frame.height) < 0.01,
                  let resolution = FrameInterpolationResolution.fitted(width: displayWidth, height: displayHeight) else {
                throw failure(L("捕获尺寸与窗口比例不一致，已保留原画面"))
            }
            processingResolution = resolution
            let processor = FrameInterpolationEngine(width: resolution.width, height: resolution.height)
            engine = processor
            try await processor.prepare()
            guard token == generation else { processor.close(); return }
            try createOverlay(frame: window.frame)
            let config = SCStreamConfiguration()
            config.width = resolution.width; config.height = resolution.height
            config.scalesToFit = true
            // Alignment can slightly change the intermediate aspect ratio; the
            // presenter maps back to the original physical dimensions exactly.
            config.preservesAspectRatio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.capturesAudio = false; config.captureMicrophone = false
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            // Stable mode budgets 30 captured frames / 60 presented frames,
            // leaving processing headroom when the game fluctuates around 40.
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3
            let (frames, continuation) = AsyncStream<InterpolationImage>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let output = InterpolationCaptureSink(continuation)
            let capture = SCStream(filter: filter, configuration: config, delegate: nil)
            try capture.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "indie.interpolation.capture"))
            stream = capture; sink = output
            try await capture.startCapture()
            guard token == generation else { try? await capture.stopCapture(); return }
            worker = Task { [weak self] in
                var previous: InterpolationImage?
                for await current in frames {
                    guard let self, token == self.generation, !Task.isCancelled else { return }
                    self.received += 1
                    guard self.visibilityGate.canPresent else { previous = nil; continue }
                    let visibilityEpoch = self.visibilityGate.epoch
                    guard let old = previous else { previous = current; continue }
                    guard Date() >= self.cooldownUntil else { previous = current; continue }
                    self.processingInFlight = true
                    let began = CACurrentMediaTime()
                    self.processingStartedAt = began
                    let analysis = await self.analyzer.analyze(previous: old, current: current)
                    guard token == self.generation, !Task.isCancelled else { return }
                    guard self.visibilityGate.accepts(epoch: visibilityEpoch) else {
                        self.processingInFlight = false; previous = nil; continue
                    }
                    if analysis.duplicate {
                        // Capture refreshes can outnumber game frames. Keep the
                        // last distinct image/timestamp and queued output intact.
                        // The independent watchdog handles sustained stillness.
                        self.processingInFlight = false
                        continue
                    }
                    previous = current
                    if analysis.sceneCut {
                        self.processingInFlight = false
                        self.pacer.reset()
                        self.overlay?.orderOut(nil)
                        self.presenter?.pause()
                        // Scene cuts reveal the original immediately.
                        self.lastProgress = Date()
                        continue
                    }
                    let a = old.timestamp.seconds, b = current.timestamp.seconds
                    guard let midpoint = FrameInterpolationTiming.midpoint(previous: a, current: b) else {
                        self.processingInFlight = false
                        self.pacer.reset()
                        self.presenter?.pause()
                        self.overlay?.orderOut(nil)
                        continue
                    }
                    do {
                        let generated = try await processor.interpolate(previous: old, current: current)
                        guard token == self.generation else { return }
                        self.processingInFlight = false
                        guard self.visibilityGate.accepts(epoch: visibilityEpoch) else { previous = nil; continue }
                        let elapsed = CACurrentMediaTime() - began
                        self.processingCosts.append(elapsed)
                        if self.processingCosts.count > 600 { self.processingCosts.removeFirst(self.processingCosts.count-600) }
                        self.processed += 1
                        self.present(generated: generated, current: current, midpoint: midpoint, gap: b-a, elapsed: elapsed)
                    } catch {
                        guard token == self.generation else { return }
                        self.processingInFlight = false
                        if (error as NSError).code == -12911 && !self.hasOutput && Date().timeIntervalSince(self.began) < 8 {
                            continue // Model loading; bounded by independent watchdog.
                        }
                        self.stop(reason: L("插帧失败，已恢复原画面：\(error.localizedDescription)"), kind: .failure)
                        return
                    }
                }
            }
        } catch {
            if token == generation { stop(reason: L("插帧未启动：\(error.localizedDescription)"), kind: .failure) }
        }
    }

    private func present(generated: InterpolationImage, current: InterpolationImage, midpoint: Double, gap: Double, elapsed: Double) {
        guard visibilityGate.canPresent, let presenter else { return }
        let now = CACurrentMediaTime()
        guard let schedule = pacer.schedule(previous: midpoint-gap/2, current: current.timestamp.seconds,
            completedAt: now, processingSeconds: elapsed, refreshInterval: presenter.refreshInterval,
            presentationLead: presenter.presentationLead) else {
            dropped += 2; deadlineDrops += 2; consecutiveOverruns += 1
            if consecutiveOverruns >= 4 {
                cooldownUntil = Date().addingTimeInterval(1)
                consecutiveOverruns = 0
                overlay?.orderOut(nil); presenter.pause()
            }
            status = L("插帧输出调整中；持续超时则显示原画面")
            return
        }
        guard presenter.enqueue(generated: generated, original: current, schedule: schedule) else {
            dropped += 2; rendererBackpressure += 1; pacer.reset()
            presenter.discardQueued()
            return
        }
        submitted += 2
        consecutiveOverruns = 0
        let actual = presenter.snapshot
        let runningStatus = actual.presentedOriginal + actual.presentedGenerated > 0
            ? L("2× 插帧运行中；切出游戏时暂停") : L("正在准备插帧；原游戏画面保持可见…")
        if status != runningStatus { status = runningStatus }
        hasOutput = true
        lastProgress = Date()
        if overlay?.isVisible != true {
            overlay?.orderFrontRegardless()
        }
        if Date().timeIntervalSince(lastMetricUpdate) > 0.5 {
            let shown = presenter.snapshot
            metrics = "\(CVPixelBufferGetWidth(current.buffer))×\(CVPixelBufferGetHeight(current.buffer)) → \(displayWidth)×\(displayHeight) · \(presenter.upscaling) · \(Int(elapsed*1000)) ms · presented \(shown.presentedOriginal)+\(shown.presentedGenerated) · dropped \(dropped + shown.skipped)"
            lastMetricUpdate = Date()
        }
    }

    private func createOverlay(frame: CGRect) throws {
        guard let processingResolution else { throw failure("Missing processing resolution") }
        let window = PassthroughFrameWindow(contentRect: appKitFrame(frame), styleMask: .borderless, backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        // An opaque window can cause the source application's occlusion
        // handling to stop producing frames as soon as our overlay appears.
        window.isOpaque = false
        // WindowServer must also see translucency in the composited result:
        // the rendered frame itself has alpha 1 despite isOpaque = false.
        window.alphaValue = 0.999
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        // Wine's borderless game window uses layer 26 on this Mac, above
        // AppKit's floating level (3). Stay immediately above the target.
        window.level = NSWindow.Level(rawValue: max(NSWindow.Level.floating.rawValue,
                                                    (target?.windowLayer ?? 0) + 1))
        // The target may belong to another application's full-screen Space.
        // fullScreenAuxiliary alone does not declare cross-application joining.
        window.collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces,
                                     .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let display = try InterpolationMetalPresenter(processing: processingResolution,
            displayWidth: displayWidth, displayHeight: displayHeight,
            maximumRefreshRate: NSScreen.screens.first(where: { $0.frame.intersects(appKitFrame(frame)) })?.maximumFramesPerSecond ?? 60)
        display.layer.frame = view.bounds
        display.layer.contentsScale = Double(displayWidth) / frame.width
        view.layer?.addSublayer(display.layer)
        let token = generation
        display.onFailure = { [weak self] message in
            guard let self, self.generation == token else { return }
            self.stop(reason: L("显示层异常，已恢复原画面") + ": " + message, kind: .failure)
        }
        display.onStarvation = { [weak self] in
            guard let self, self.generation == token else { return }
            self.overlay?.orderOut(nil)
            self.pacer.reset()
        }
        window.contentView = view
        overlay = window; presenter = display
    }

    private func appKitFrame(_ cgFrame: CGRect) -> CGRect {
        CGRect(x: cgFrame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - cgFrame.maxY,
               width: cgFrame.width, height: cgFrame.height)
    }

    private func checkLifetime() {
        guard active else { return }
        let shown = presenter?.snapshot
        let expectingOutput = hasOutput && overlay?.isVisible == true && Date().timeIntervalSince(lastProgress) < 0.5
        if presentationHealth.isStalled(presented: (shown?.presentedOriginal ?? 0) + (shown?.presentedGenerated ?? 0),
                                       expectingOutput: expectingOutput, now: CACurrentMediaTime()) {
            stop(reason: L("显示层未实际呈现画面，已恢复原画面"), kind: .failure); return
        }
        if let pid = target?.owningApplication?.processID {
            guard NSRunningApplication(processIdentifier: pid) != nil else { stop(kind: .transient); return }
            if (hasOutput || Date().timeIntervalSince(began) > 3) && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                stop(reason: L("已切出游戏，等待返回后恢复插帧"), kind: .transient); return
            }
        }
        guard displayTopology == topology() else {
            stop(reason: L("显示器或缩放变化，等待重新匹配窗口"), kind: .transient); return
        }
        if Date().timeIntervalSince(began) > 10 && !hasOutput {
            stop(reason: L("设备未及时生成插帧，已保留原画面"), kind: .failure); return
        }
        if hasOutput && Date().timeIntervalSince(lastProgress) > 0.5 {
            if processingInFlight && CACurrentMediaTime() - processingStartedAt > 0.5 {
                stop(reason: L("捕获或插帧停滞，已恢复原画面"), kind: .failure); return
            }
            overlay?.orderOut(nil)
            presenter?.pause(); pacer.reset()
            status = L("画面暂无更新，显示原画面；更新后恢复插帧")
        }
        guard let target, let pid = target.owningApplication?.processID else { return }
        guard NSRunningApplication(processIdentifier: pid) != nil else { stop(kind: .transient); return }
        if Date().timeIntervalSince(began) > 3 && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            stop(reason: L("已切出游戏，等待返回后恢复插帧"), kind: .transient); return
        }
        let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        let info = list?.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID })
        let bounds = info?[kCGWindowBounds as String] as? NSDictionary
        let frame = bounds.flatMap { CGRect(dictionaryRepresentation: $0) }
        windowObservation = .init(windowID: target.windowID, ownerPID: pid,
            foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            onScreen: info?[kCGWindowIsOnscreen as String] as? Bool,
            width: frame.map { Double($0.width) }, height: frame.map { Double($0.height) },
            expectedWidth: Double(target.frame.width), expectedHeight: Double(target.frame.height),
            layer: (info?[kCGWindowLayer as String] as? NSNumber)?.intValue)
        guard let frame else { stop(kind: .transient); return }
        // Geometry/closure/focus changes still require a fresh capture filter.
        // Only a brief offscreen flag gets a bounded recovery period.
        if frame.size != target.frame.size {
            stop(reason: L("窗口尺寸或可见性变化，插帧停止"), kind: .transient); return
        }
        let wasVisible = visibilityGate.canPresent
        switch visibilityGate.observe(isVisible: info?[kCGWindowIsOnscreen as String] as? Bool == true,
                                      now: CACurrentMediaTime()) {
        case .suspended:
            if wasVisible { visibilitySuspensions += 1 }
            overlay?.orderOut(nil); presenter?.pause(); pacer.reset()
            status = L("画面暂无更新，显示原画面；更新后恢复插帧")
            return
        case .expired:
            stop(reason: L("窗口尺寸或可见性变化，插帧停止"), kind: .transient); return
        case .visible:
            if !wasVisible {
                visibilityRecoveries += 1
                pacer.reset()
            }
        }
        overlay?.setFrame(appKitFrame(frame), display: false)
    }

    func stop(reason: String? = nil, kind: StopKind = .manual) {
        // Preserve the last counters and observation after cleanup so the probe
        // can distinguish geometry, visibility, foreground and processing failures.
        if active {
            var final = diagnostics
            final.active = false
            final.status = reason ?? L("插帧已关闭")
            final.stopKind = String(describing: kind)
            terminalDiagnostics = final
        }
        generation = UUID()
        active = false
        watchdog?.invalidate(); watchdog = nil
        worker?.cancel(); worker = nil
        sink?.continuation.finish(); sink = nil
        if let capture = stream { Task { try? await capture.stopCapture() } }
        stream = nil
        engine?.close(); engine = nil
        presenter?.stop(); presenter = nil
        overlay?.orderOut(nil); overlay?.close(); overlay = nil
        target = nil; hasOutput = false; processed = 0; submitted = 0; dropped = 0; pacer.reset()
        processingResolution = nil; displayWidth = 0; displayHeight = 0
        processingCosts.removeAll(); deadlineDrops = 0; consecutiveOverruns = 0; cooldownUntil = .distantPast
        received = 0; rendererBackpressure = 0
        processingInFlight = false
        visibilityGate = FrameInterpolationVisibilityGate()
        presentationHealth = FrameInterpolationPresentationHealth()
        visibilitySuspensions = 0; visibilityRecoveries = 0; windowObservation = nil
        status = reason ?? L("插帧已关闭")
        onStopped?(kind)
    }

    private func failure(_ description: String) -> NSError {
        NSError(domain: "Indie.FrameInterpolation", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func topology() -> String {
        NSScreen.screens.map {
            "\($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "?"):\($0.frame):\($0.backingScaleFactor)"
        }.joined(separator: ";")
    }

}
