import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// 全 App 共享一个 CIContext：CIContext 是线程安全的昂贵对象，不要每张图新建（上一版每次都 new，代价很大）。
enum ImagePipeline {
    static let context = CIContext(options: [.useSoftwareRenderer: false])
}

/// 一次成片的渲染参数：滤镜 + 调色 + 构图风格 + 可选美颜。
struct PhotoRenderOptions {
    var filter: PhotoFilter = .natural
    var grade: ColorGrade = ColorGrade()
    var style: String = "自然"
    var beauty: PortraitBeautySettings? = nil
    var filterStrength: Double = 0.55
    var directorContext: DirectorLearningContext? = nil
    var directorEvidence: [DirectorEvidence] = []
}

/// 统一的后处理入口：原片 → （美颜）→ 滤镜 → 调色 → 一次渲染。
/// 全部步骤都在 Core Image 里串成一条管线，只在最后 createCGImage 一次。
enum PhotoPostProcessor {
    static func render(original: UIImage, options: PhotoRenderOptions) -> UIImage? {
        var base = original
        if let beauty = options.beauty, let beautified = PortraitBeautyEngine.shared.process(original, settings: beauty) {
            base = beautified
        }
        guard let cg = base.cgImage else { return nil }

        var ci = CIImage(cgImage: cg).oriented(exifOrientation(base.imageOrientation))
        ci = applyColor(to: ci, options: options)
        guard let output = ImagePipeline.context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: output, scale: 1, orientation: .up)
    }

    static func applyColor(to input: CIImage, options: PhotoRenderOptions) -> CIImage {
        let filtered = PhotoFilterEngine.apply(options.filter, to: input)
        let graded = ColorGradeEngine.apply(options.grade.applyingStyle(options.style), to: filtered)
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = input; mix.targetImage = graded
        mix.time = Float(max(0, min(1, options.filterStrength)))
        return (mix.outputImage ?? input).cropped(to: input.extent)
    }

    /// 保存用的 JPEG 数据（质量 0.95）。
    static func jpegData(_ image: UIImage, quality: CGFloat = 0.95) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    static func exifOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
