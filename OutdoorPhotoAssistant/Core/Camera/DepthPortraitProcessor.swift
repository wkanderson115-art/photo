import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// 把 Portrait Effects Matte 转成景深人像（背景虚化、人物保留）和可拖拽视差用的遮罩。
/// 关键修正：底图与遮罩必须在同一个"正立坐标系"里再对齐，否则 3:4 照片会明显错位。
enum DepthPortraitProcessor {
    static func makePortrait(image: UIImage, matte: AVPortraitEffectsMatte) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let exif = PhotoPostProcessor.exifOrientation(image.imageOrientation)
        let base = CIImage(cgImage: cg).oriented(exif)
        let mask = fitExact(CIImage(cvPixelBuffer: matte.mattingImage).oriented(exif), to: base.extent)

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(base, forKey: kCIInputImageKey)
        blur.setValue(Float(max(4, base.extent.width * 0.004)), forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage?.cropped(to: base.extent) else { return nil }

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(base, forKey: kCIInputImageKey)
        blend.setValue(blurred, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage else { return nil }
        guard let outCG = ImagePipeline.context.createCGImage(output, from: base.extent) else { return nil }
        return UIImage(cgImage: outCG, scale: 1, orientation: .up)
    }

    static func makePortraitMask(image: UIImage, matte: AVPortraitEffectsMatte) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let exif = PhotoPostProcessor.exifOrientation(image.imageOrientation)
        let base = CIImage(cgImage: cg).oriented(exif)
        let mask = fitExact(CIImage(cvPixelBuffer: matte.mattingImage).oriented(exif), to: base.extent)
        guard let outCG = ImagePipeline.context.createCGImage(mask, from: base.extent) else { return nil }
        return UIImage(cgImage: outCG, scale: 1, orientation: .up)
    }

    private static func fitExact(_ image: CIImage, to extent: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        return image
            .transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width,
                                               y: extent.height / image.extent.height))
            .cropped(to: extent)
    }
}
