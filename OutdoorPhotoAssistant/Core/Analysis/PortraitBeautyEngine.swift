import Foundation
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// 美颜强度上限全部写死在小范围内：目标是保留真实纹理，而不是"塑料脸"。
struct PortraitBeautySettings: Equatable {
    var skin: Double = 0.22
    var clarity: Double = 0.08
    var faceDepth: Double = 0.08
    var faceSlim: Double = 0.05
    var eyeLift: Double = 0.04
    var environmentBlend: Double = 0.16
}

/// 轻量、离线的人像优化。只有检测到人脸时才生效，否则返回 nil（调用方直接使用原图）。
final class PortraitBeautyEngine {
    static let shared = PortraitBeautyEngine()

    private let context = ImagePipeline.context

    func process(_ image: UIImage, settings: PortraitBeautySettings = PortraitBeautySettings()) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let exif = PhotoPostProcessor.exifOrientation(image.imageOrientation)
        let ci = CIImage(cgImage: cg).oriented(exif)

        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: ci, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        let faces = (request.results ?? []).sorted {
            ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height)
        }
        guard let face = faces.first else { return nil }

        let extent = ci.extent
        let faceRect = visionRect(face.boundingBox, in: extent)
        guard faceRect.width > 4, faceRect.height > 4 else { return nil }

        var result = ci

        // 1) 只对皮肤区域柔和处理，眼睛与嘴唇从遮罩里扣除。
        if settings.skin > 0.001, let mask = skinMask(face: face, extent: extent) {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = result
            blur.radius = Float(min(6.0, 1.2 + settings.skin * 8.0))
            if let blurred = blur.outputImage?.cropped(to: extent) {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = blurred
                blend.backgroundImage = result
                blend.maskImage = mask
                if let blended = blend.outputImage {
                    let amount = min(0.30, max(0, settings.skin) * 0.42)
                    result = blendOpacity(foreground: blended, background: result, amount: amount, extent: extent)
                }
            }
        }

        // 2) 面部立体：非常小的中心鼓起。
        if settings.faceDepth > 0.001 {
            let warp = CIFilter.bumpDistortion()
            warp.inputImage = result
            warp.center = CGPoint(x: faceRect.midX, y: faceRect.midY + faceRect.height * 0.04)
            warp.radius = Float(min(faceRect.width, faceRect.height) * 0.40)
            warp.scale = Float(min(0.015, max(0, settings.faceDepth) * 0.045))
            if let output = warp.outputImage?.cropped(to: extent) { result = output }
        }

        // 3) 轮廓微调：小幅 inward warp，强度严格封顶。
        if settings.faceSlim > 0.001 {
            let warp = CIFilter.bumpDistortion()
            warp.inputImage = result
            warp.center = CGPoint(x: faceRect.midX, y: faceRect.midY)
            warp.radius = Float(min(faceRect.width, faceRect.height) * 0.58)
            warp.scale = Float(-min(0.025, max(0, settings.faceSlim) * 0.075))
            if let output = warp.outputImage?.cropped(to: extent) { result = output }
        }

        // 4) 眼神提亮（不是放大眼睛）。
        if settings.eyeLift > 0.001, let landmarks = face.landmarks {
            let eyes = [landmarks.leftEye, landmarks.rightEye].compactMap { $0 }
            for eye in eyes {
                guard let eyeMask = regionMask(eye, face: face, extent: extent) else { continue }
                let bright = CIFilter.colorControls()
                bright.inputImage = result
                bright.brightness = Float(min(0.045, max(0, settings.eyeLift) * 0.20))
                bright.contrast = Float(1.0 + min(0.03, max(0, settings.eyeLift) * 0.08))
                if let output = bright.outputImage {
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = output
                    blend.backgroundImage = result
                    blend.maskImage = eyeMask
                    if let eyeResult = blend.outputImage { result = eyeResult.cropped(to: extent) }
                }
            }
        }

        result = colorFinish(result, settings: settings)
        guard let out = context.createCGImage(result, from: extent) else { return nil }
        return UIImage(cgImage: out, scale: 1, orientation: .up)
    }

    // MARK: - 基础画面微调

    private func colorFinish(_ image: CIImage, settings: PortraitBeautySettings) -> CIImage {
        let color = CIFilter.colorControls()
        color.inputImage = image
        color.saturation = Float(1.0 + min(0.04, max(0, settings.environmentBlend) * 0.08))
        color.contrast = Float(1.0 + min(0.04, max(0, settings.clarity) * 0.10))
        color.brightness = 0
        return color.outputImage ?? image
    }

    // MARK: - 遮罩
    //
    // 关键修正：画布尺寸必须与图像宽高比一致。
    // 上一版用 512×512 方形画布 + 等比缩放居中裁切，导致 3:4 照片里的
    // 人脸/眼睛遮罩被横向压缩并整体偏移，磨皮和瘦脸会作用到错误区域。

    private func skinMask(face: VNFaceObservation, extent: CGRect) -> CIImage? {
        let size = canvasSize(for: extent)
        guard let ctx = makeGrayContext(size) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))

        let b = face.boundingBox
        let rect = CGRect(x: b.minX * size.width,
                          y: b.minY * size.height,
                          width: b.width * size.width,
                          height: b.height * size.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: rect.insetBy(dx: -rect.width * 0.06, dy: -rect.height * 0.04))

        if let landmarks = face.landmarks {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for region in [landmarks.leftEye, landmarks.rightEye, landmarks.outerLips].compactMap({ $0 }) {
                let points = region.normalizedPoints.map { p in
                    CGPoint(x: (b.minX + p.x * b.width) * size.width,
                            y: (b.minY + p.y * b.height) * size.height)
                }
                drawPolygon(points, in: ctx)
            }
        }
        return finishMask(ctx, size: size, extent: extent)
    }

    private func regionMask(_ region: VNFaceLandmarkRegion2D, face: VNFaceObservation, extent: CGRect) -> CIImage? {
        let size = canvasSize(for: extent)
        guard let ctx = makeGrayContext(size) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let b = face.boundingBox
        let points = region.normalizedPoints.map { p in
            CGPoint(x: (b.minX + p.x * b.width) * size.width,
                    y: (b.minY + p.y * b.height) * size.height)
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        drawPolygon(points, in: ctx)
        return finishMask(ctx, size: size, extent: extent)
    }

    private func drawPolygon(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }

    private func finishMask(_ ctx: CGContext, size: CGSize, extent: CGRect) -> CIImage? {
        guard let cg = ctx.makeImage() else { return nil }
        let mask = fitExact(CIImage(cgImage: cg), to: extent)
        let radius = Float(max(2, extent.width * 0.004))
        return mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
    }

    private func canvasSize(for extent: CGRect) -> CGSize {
        let longSide: CGFloat = 512
        guard extent.width > 0, extent.height > 0 else { return CGSize(width: 512, height: 512) }
        let aspect = extent.height / extent.width
        if aspect >= 1 {
            return CGSize(width: max(64, (longSide / aspect).rounded()), height: longSide)
        }
        return CGSize(width: longSide, height: max(64, (longSide * aspect).rounded()))
    }

    private func makeGrayContext(_ size: CGSize) -> CGContext? {
        CGContext(data: nil,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    private func fitExact(_ image: CIImage, to extent: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0 else { return image }
        return image
            .transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width,
                                               y: extent.height / image.extent.height))
            .cropped(to: extent)
    }

    private func visionRect(_ box: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + box.minX * extent.width,
               y: extent.minY + box.minY * extent.height,
               width: box.width * extent.width,
               height: box.height * extent.height)
    }

    private func blendOpacity(foreground: CIImage, background: CIImage, amount: Double, extent: CGRect) -> CIImage {
        let gray = CIColor(red: CGFloat(amount), green: CGFloat(amount), blue: CGFloat(amount), alpha: 1)
        let mask = CIImage(color: gray).cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = background
        blend.maskImage = mask
        return blend.outputImage ?? foreground
    }
}
