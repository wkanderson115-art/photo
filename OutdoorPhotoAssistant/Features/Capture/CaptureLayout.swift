import CoreGraphics

/// Pure layout maths for the camera screen, kept free of SwiftUI so it can be tested.
enum CaptureLayout {
    static func isLandscape(_ size: CGSize) -> Bool { size.width > size.height }

    /// Still photos from the selected iPhone photo formats are 4:3.  Keep the
    /// viewfinder on the same aspect so the user sees the full delivered frame.
    static func photoAspect(landscape: Bool) -> CGFloat {
        landscape ? 4.0 / 3.0 : 3.0 / 4.0
    }

    /// `AVCaptureDevice.RotationCoordinator` normally returns quarter turns, but
    /// it can briefly report a fractional value while the phone is moving.  A
    /// photo must use a stable quarter turn, otherwise a connection may reject it.
    static func normalizedRotationAngle(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 90 }
        let wrapped = angle.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        let quarterTurn = (positive / 90).rounded() * 90
        return quarterTurn >= 360 ? 0 : quarterTurn
    }

    static func isLandscape(rotationAngle: CGFloat) -> Bool {
        let angle = normalizedRotationAngle(rotationAngle)
        return angle == 0 || angle == 180
    }

    /// Width / height the preview should take. The analysis frame can lag behind a rotation by a
    /// moment.  The delivered still is always 4:3, so do not let a transient 16:9
    /// analysis buffer change or crop the viewfinder.
    static func previewAspect(frameAspect: CGFloat, landscape: Bool) -> CGFloat {
        _ = frameAspect // Kept in the signature for callers and stale-frame tests.
        return photoAspect(landscape: landscape)
    }

    /// Largest rectangle with `aspect` (width / height) that fits `available`.
    static func fit(aspect: CGFloat, in available: CGSize) -> CGSize {
        guard aspect > 0, available.width > 0, available.height > 0 else { return .zero }
        let width = min(available.width, available.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }
}
