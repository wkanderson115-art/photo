import CoreGraphics

/// Pure layout maths for the camera screen, kept free of SwiftUI so it can be tested.
enum CaptureLayout {
    static func isLandscape(_ size: CGSize) -> Bool { size.width > size.height }

    /// Width / height the preview should take. The analysis frame can lag behind a rotation by a
    /// moment, so a frame in the "wrong" orientation is flipped instead of trusted.
    static func previewAspect(frameAspect: CGFloat, landscape: Bool) -> CGFloat {
        let fallback: CGFloat = landscape ? 4.0 / 3.0 : 0.75
        let raw = frameAspect.isFinite && frameAspect > 0 ? frameAspect : fallback
        if landscape {
            return min(2, max(1, raw >= 1 ? raw : 1 / raw))
        }
        return min(1, max(0.5, raw <= 1 ? raw : 1 / raw))
    }

    /// Largest rectangle with `aspect` (width / height) that fits `available`.
    static func fit(aspect: CGFloat, in available: CGSize) -> CGSize {
        guard aspect > 0, available.width > 0, available.height > 0 else { return .zero }
        let width = min(available.width, available.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }
}
