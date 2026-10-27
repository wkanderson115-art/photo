import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Conservative local blend of two already aligned, equally sized images.
/// This is not automatic Seedream integration and cannot fix geometry changes.
final class SafeFusion {
    enum Failure: LocalizedError {
        case incompatible, invalidMask, renderFailed
        var errorDescription: String? {
            switch self {
            case .incompatible: return "AI 图像尺寸或方向不匹配，拒绝自动融合"
            case .invalidMask: return "没有有效局部蒙版，拒绝全图覆盖"
            case .renderFailed: return "融合渲染失败"
            }
        }
    }
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!])
    /// A safety-first automatically derived mask. Only small edits with matching pixel geometry
    /// are eligible; creative/global Seedream edits remain separate versions for manual review.
    func conservativeMask(local: UIImage, ai: UIImage) throws -> CIImage {
        guard let a = local.cgImage, let b = ai.cgImage,
              a.width == b.width, a.height == b.height,
              a.width >= 320, a.height >= 320 else { throw Failure.incompatible }
        let w = 128, h = 128
        func pixels(_ cg: CGImage) throws -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w*h*4)
            let ok = out.withUnsafeMutableBytes { ptr -> Bool in
                guard let base = ptr.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            if !ok { throw Failure.renderFailed }
            return out
        }
        let x = try pixels(a), y = try pixels(b)
        var changed = 0, large = 0
        var mask = [UInt8](repeating: 0, count: w*h*4)
        for i in 0..<(w*h) {
            let d = (0..<3).reduce(0) { $0 + abs(Int(x[i*4+$1]) - Int(y[i*4+$1])) } / 3
            if d > 12 { changed += 1 }
            if d > 65 { large += 1 }
            let v: UInt8 = d > 12 && d < 65 ? 255 : 0
            mask[i*4] = v; mask[i*4+1] = v; mask[i*4+2] = v; mask[i*4+3] = 255
        }
        // Strong global edits / substantial regeneration cannot be registered reliably.
        guard changed > 0, Double(changed)/Double(w*h) < 0.08,
              Double(large)/Double(w*h) < 0.01 else { throw Failure.invalidMask }
        let data = Data(mask)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Failure.renderFailed }
        let extent = CGRect(x: 0, y: 0, width: a.width, height: a.height)
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: CGFloat(a.width)/CGFloat(w), y: CGFloat(a.height)/CGFloat(h)))
            .clampedToExtent().cropped(to: extent)
    }
    func blend(local: UIImage, ai: UIImage, mask: CIImage) throws -> UIImage {
        guard let base = local.cgImage, let modified = ai.cgImage,
              base.width == modified.width, base.height == modified.height,
              local.imageOrientation == .up, ai.imageOrientation == .up else { throw Failure.incompatible }
        let extent = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        guard mask.extent.contains(extent) else { throw Failure.invalidMask }
        let filter = CIFilter.blendWithMask()
        filter.inputImage = CIImage(cgImage: modified)
        filter.backgroundImage = CIImage(cgImage: base)
        filter.maskImage = mask.cropped(to: extent)
        guard let result = filter.outputImage?.cropped(to: extent),
              let cg = context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw Failure.renderFailed }
        return UIImage(cgImage: cg)
    }
}
