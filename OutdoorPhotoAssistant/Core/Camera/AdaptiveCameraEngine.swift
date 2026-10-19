import AVFoundation
import Foundation

/// 设备自适应引擎：按内存/核心数/热状态/低电量选择档位，并把档位真正用起来
/// （控制 HDR、拍照质量优先级、是否请求最大照片尺寸）。
final class AdaptiveCameraEngine {
    enum Tier: String {
        case light = "轻量"
        case balanced = "均衡"
        case high = "高性能"
    }

    struct Profile {
        let tier: Tier
        let enableHDR: Bool
        let preferQualityCapture: Bool
        let allowMaxDimensions: Bool

        var summary: String {
            switch tier {
            case .light: return "低负载·硬件优先"
            case .balanced: return "均衡·画质优先"
            case .high: return "高性能·极致画质"
            }
        }
    }

    private(set) var profile = AdaptiveCameraEngine.makeProfile()

    static func makeProfile() -> Profile {
        let info = ProcessInfo.processInfo
        let memoryGB = Double(info.physicalMemory) / 1_073_741_824.0
        let cores = info.processorCount
        let thermal = info.thermalState
        let lowPower = info.isLowPowerModeEnabled

        if thermal == .serious || thermal == .critical || memoryGB < 3.0 || cores <= 4 || lowPower {
            return Profile(tier: .light,
                           enableHDR: false,
                           preferQualityCapture: true,
                           allowMaxDimensions: false)
        }
        if memoryGB >= 6.0 && cores >= 6 && thermal == .nominal {
            return Profile(tier: .high,
                           enableHDR: true,
                           preferQualityCapture: true,
                           allowMaxDimensions: true)
        }
        return Profile(tier: .balanced,
                       enableHDR: true,
                       preferQualityCapture: true,
                       allowMaxDimensions: true)
    }

    func refreshProfile() {
        profile = Self.makeProfile()
    }

    /// 只做"能让硬件自动算法参与"的配置，不用软件模拟 AE/AF/AWB。
    func configure(_ device: AVCaptureDevice) {
        refreshProfile()
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = profile.enableHDR
            }
        } catch {
            // 个别机型不支持其中某项时，保留其它已成功设置的能力。
        }
    }

    func prepare(_ settings: AVCapturePhotoSettings,
                 output: AVCapturePhotoOutput,
                 highQuality: Bool) {
        refreshProfile()
        settings.flashMode = .off
        settings.photoQualityPrioritization = profile.preferQualityCapture ? .quality : .balanced
        if output.isVirtualDeviceFusionSupported {
            settings.isAutoVirtualDeviceFusionEnabled = true
        }
        if output.isContentAwareDistortionCorrectionEnabled {
            settings.isAutoContentAwareDistortionCorrectionEnabled = true
        }

        if highQuality && profile.allowMaxDimensions {
            settings.maxPhotoDimensions = output.maxPhotoDimensions
        }

        // 关键：只有输出层真的打开了 depth / matte，才能往照片请求里加，
        // 否则 AVFoundation 会抛异常（这是上一版"按下快门即崩溃"的根因）。
        if output.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = true
            if output.isPortraitEffectsMatteDeliveryEnabled {
                settings.isPortraitEffectsMatteDeliveryEnabled = true
                settings.embedsPortraitEffectsMatteInPhoto = true
            }
        }
    }
}
