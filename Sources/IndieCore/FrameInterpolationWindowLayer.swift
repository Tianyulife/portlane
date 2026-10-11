/// Capture normal app windows and Wine's borderless/full-screen render window.
/// Keep menu, desktop and system overlay layers outside automatic matching.
public enum FrameInterpolationWindowLayer {
    public static func isEligible(_ layer: Int) -> Bool {
        layer == 0 || layer == 26
    }
}
