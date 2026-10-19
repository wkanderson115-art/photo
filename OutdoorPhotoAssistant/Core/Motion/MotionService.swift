import Combine
import CoreMotion
import Foundation

/// 陀螺仪水平与稳定度。只在主线程更新 @Published。
final class MotionService: ObservableObject {
    private let manager = CMMotionManager()

    @Published var roll: Double = 0
    @Published var pitch: Double = 0
    @Published var isLevel = false
    @Published var isStable = false
    @Published var stabilityScore: Int = 0

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = motion.attitude.roll
            let rotation = hypot(motion.rotationRate.x, hypot(motion.rotationRate.y, motion.rotationRate.z))
            self.roll = roll
            self.pitch = motion.attitude.pitch
            self.isLevel = abs(roll) < 0.035
            self.isStable = rotation < 0.12
            self.stabilityScore = max(0, min(100, Int((1 - min(rotation / 0.6, 1)) * 100)))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
