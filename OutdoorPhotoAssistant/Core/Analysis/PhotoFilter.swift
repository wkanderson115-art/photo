import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// 15 套内置滤镜（README 已与实际数量对齐）。
enum PhotoFilter: String, CaseIterable, Identifiable {
    case natural = "自然"
    case vivid = "鲜艳"
    case warm = "暖阳"
    case sunset = "日落"
    case landscape = "风景"
    case portrait = "人像"
    case cool = "清冷"
    case night = "夜景"
    case blackWhite = "黑白"
    case film = "胶片"
    case cinematic = "电影"
    case neon = "霓虹"
    case forest = "森系"
    case cream = "奶油人像"
    case gold = "黑金"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .natural: return "leaf"
        case .vivid: return "sparkles"
        case .warm: return "sun.max"
        case .sunset: return "sunset"
        case .landscape: return "mountain.2"
        case .portrait: return "person.crop.circle"
        case .cool: return "snowflake"
        case .night: return "moon.stars"
        case .blackWhite: return "circle.lefthalf.filled"
        case .film: return "camera.filters"
        case .cinematic: return "film"
        case .neon: return "lightspectrum.horizontal"
        case .forest: return "tree"
        case .cream: return "person.crop.circle"
        case .gold: return "sparkles"
        }
    }

    static func recommended(scene: String, brightness: Double, period: String) -> PhotoFilter {
        if period == "蓝调时刻" && (scene == "风景" || scene == "海边") { return .cool }
        if period == "黄金时段" && (scene == "风景" || scene == "日落") { return .sunset }
        if scene == "人物" || scene == "自拍" { return brightness < 0.22 ? .cream : .portrait }
        if scene == "日落" { return .sunset }
        if scene == "夜景" || period == "夜景" { return .night }
        if scene == "海边" { return .cool }
        if scene == "花草" { return .forest }
        if scene == "风景" { return brightness > 0.75 ? .landscape : .film }
        if scene == "建筑" { return .cinematic }
        if scene == "汽车" { return .gold }
        return .natural
    }
}

/// 滤镜的 Core Image 实现：输入输出都是 CIImage，便于与调色串成一条管线。
enum PhotoFilterEngine {
    static func apply(_ filter: PhotoFilter, to input: CIImage) -> CIImage {
        switch filter {
        case .natural:
            return input
        case .vivid:
            return colorControls(input, saturation: 1.18, contrast: 1.06, brightness: 0.01)
        case .warm:
            return temperature(input, target: 5900, tint: 0)
        case .sunset:
            let warmed = temperature(input, target: 5200, tint: 4)
            return colorControls(warmed, saturation: 1.12, contrast: 1.08, brightness: 0)
        case .landscape:
            return colorControls(input, saturation: 1.10, contrast: 1.10, brightness: 0)
        case .portrait:
            return colorControls(input, saturation: 1.02, contrast: 0.98, brightness: 0.015)
        case .cool:
            return temperature(input, target: 7200, tint: -2)
        case .night:
            return colorControls(input, saturation: 0.94, contrast: 1.03, brightness: 0)
        case .blackWhite:
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = input
            return mono.outputImage ?? input
        case .film:
            return colorControls(input, saturation: 0.94, contrast: 1.04, brightness: 0.008)
        case .cinematic:
            return colorControls(input, saturation: 0.92, contrast: 1.12, brightness: 0)
        case .neon:
            return colorControls(input, saturation: 1.30, contrast: 1.12, brightness: 0)
        case .forest:
            return colorControls(input, saturation: 1.12, contrast: 1.06, brightness: 0)
        case .cream:
            return colorControls(input, saturation: 0.98, contrast: 0.96, brightness: 0.02)
        case .gold:
            return colorControls(input, saturation: 1.06, contrast: 1.16, brightness: 0)
        }
    }

    private static func colorControls(_ input: CIImage, saturation: Float, contrast: Float, brightness: Float) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = input
        filter.saturation = saturation
        filter.contrast = contrast
        filter.brightness = brightness
        return filter.outputImage ?? input
    }

    private static func temperature(_ input: CIImage, target: CGFloat, tint: CGFloat) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = input
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: target, y: tint)
        return filter.outputImage ?? input
    }
}
