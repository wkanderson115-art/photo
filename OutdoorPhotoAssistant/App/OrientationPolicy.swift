import UIKit

/// Which interface orientations the app may use right now.
/// The camera screen can rotate; every other screen stays portrait, as before.
enum AppOrientation {
    static var mask: UIInterfaceOrientationMask = .portrait
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppOrientation.mask
    }
}

enum OrientationPolicy {
    /// Call on the main thread. Narrowing to `.portrait` also rotates a landscape screen back.
    static func apply(_ mask: UIInterfaceOrientationMask) {
        AppOrientation.mask = mask
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}
