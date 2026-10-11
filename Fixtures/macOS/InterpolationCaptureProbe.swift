import AppKit
import IndieCore
import ScreenCaptureKit

@main struct InterpolationCaptureProbe {
    @MainActor static func main() {
        guard #available(macOS 26, *) else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                func argument(_ key: String) -> String? {
                    guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { return nil }
                    return CommandLine.arguments[index+1]
                }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                if CommandLine.arguments.contains("--list") {
                    let selectedPID = argument("--pid").flatMap(Int32.init)
                    for window in content.windows {
                        if let selectedPID {
                            guard window.owningApplication?.processID == selectedPID else { continue }
                        } else {
                            guard window.isOnScreen && FrameInterpolationWindowLayer.isEligible(window.windowLayer) && window.frame.width >= 320 && window.frame.height >= 200 && !(window.title ?? "").isEmpty else { continue }
                        }
                        print("id=\(window.windowID) pid=\(window.owningApplication?.processID ?? 0) owner=\(window.owningApplication?.applicationName ?? "") title=\(window.title ?? "") size=\(window.frame.size) layer=\(window.windowLayer) onScreen=\(window.isOnScreen)")
                    }
                    exit(0)
                }
                let selected = argument("--window").flatMap(UInt32.init)
                guard let window = content.windows.first(where: { window in
                    if let selected { return window.windowID == selected }
                    return window.title == "MGU interpolation test pattern"
                }) else {
                    print("test pattern absent"); exit(1)
                }
                await GameFrameInterpolation.shared.start(windowID: window.windowID)
                var samples: [GameFrameInterpolation.DiagnosticSnapshot] = []
                let duration = max(1, Int(argument("--duration") ?? "20") ?? 20)
                // Count wall-clock duration, not samples: capture and diagnostic
                // work otherwise accumulates beyond the requested test window.
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(duration))
                while clock.now < deadline {
                    try await Task.sleep(until: min(clock.now.advanced(by: .seconds(1)), deadline), clock: clock)
                    samples.append(GameFrameInterpolation.shared.diagnostics)
                    print(GameFrameInterpolation.shared.status, GameFrameInterpolation.shared.metrics)
                    if !GameFrameInterpolation.shared.active { break }
                }
                let success = GameFrameInterpolation.shared.active && samples.last.map {
                    $0.presentation.presentedGenerated > 0 && $0.presentation.presentedOriginal > 0
                } == true
                if let path = argument("--output") {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(samples).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                GameFrameInterpolation.shared.stop()
                print("stopped=\(!GameFrameInterpolation.shared.active)")
                exit(success ? 0 : 2)
            } catch { print(error); exit(3) }
        }
        app.run()
    }
}
