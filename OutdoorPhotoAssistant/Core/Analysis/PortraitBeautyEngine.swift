import Foundation
import AVFoundation
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// 美颜强度上限全部写死在小范围内：目标是保留真实纹理，而不是"塑料脸"。
struct PortraitBeautySettings: Equatable {
    var skin: Double = 0.10
    var clarity: Double = 0.08
    var faceDepth: Double = 0
    var faceSlim: Double = 0
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

        guard let result = processCI(ci, settings: settings),
              let out = context.createCGImage(result, from: ci.extent) else { return nil }
        return UIImage(cgImage: out, scale: 1, orientation: .up)
    }

    /// Same native pipeline for live preview and full-resolution stills.
    func processCI(_ ci: CIImage, settings: PortraitBeautySettings) -> CIImage? {
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
        if settings.skin > 0.001 {
            let radius = max(1, min(24, extent.width / 300))
            let blurred = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
            // CainCamera's high-pass + detail-dependent blend, ported from GLSL to Core Image.
            // Face landmark masks further protect eyes, eyebrows and lips. No Face++ SDK.
            let smoothed = CainBeautyKernels.apply(source: ci, blurred: blurred, intensity: min(0.30, max(0, settings.skin)))
            for face in faces.prefix(6) {
                guard let mask = skinMask(face: face, extent: extent) else { continue }
                result = smoothed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask]).cropped(to: extent)
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
        return result.cropped(to: extent)
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
            for region in [landmarks.leftEye, landmarks.rightEye, landmarks.leftEyebrow, landmarks.rightEyebrow, landmarks.outerLips].compactMap({ $0 }) {
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

/// Modified 2026-10-24: Swift/Core Image port of CainCamera high-pass and adjust GLSL.
/// Copyright 2018 cain.huang@outlook.com. Apache-2.0; full license in app Settings and ThirdParty.
enum CainBeautyKernels {
    private static let highPass = CIColorKernel(source: """
        kernel vec4 highPass(__sample source, __sample blur) {
            vec3 delta = source.rgb - blur.rgb;
            return vec4(clamp(48.0 * delta * delta, 0.0, 1.0), 1.0);
        }
        """)
    private static let adjust = CIColorKernel(source: """
        kernel vec4 adjust(__sample source, __sample blur, __sample detail, float intensity) {
            float value = clamp((min(source.b, blur.b) - 0.2) * 5.0, 0.0, 1.0);
            float maximum = max(max(detail.r, detail.g), detail.b);
            float amount = (1.0 - maximum / (maximum + 0.2)) * value * intensity;
            return vec4(mix(source.rgb, blur.rgb, amount), source.a);
        }
        """)
    static func apply(source: CIImage, blurred: CIImage, intensity: Double) -> CIImage {
        guard let high = highPass?.apply(extent: source.extent, arguments: [source, blurred]) else { return source.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": blurred, "inputTime": min(0.30, max(0, intensity))]) }
        let detail = high.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, source.extent.width / 600)]).cropped(to: source.extent)
        return adjust?.apply(extent: source.extent, arguments: [source, blurred, detail, intensity]) ?? source
    }
    static let licenseText = """
                                     Apache License
                               Version 2.0, January 2004
                            http://www.apache.org/licenses/
    
       TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION
    
       1. Definitions.
    
          "License" shall mean the terms and conditions for use, reproduction,
          and distribution as defined by Sections 1 through 9 of this document.
    
          "Licensor" shall mean the copyright owner or entity authorized by
          the copyright owner that is granting the License.
    
          "Legal Entity" shall mean the union of the acting entity and all
          other entities that control, are controlled by, or are under common
          control with that entity. For the purposes of this definition,
          "control" means (i) the power, direct or indirect, to cause the
          direction or management of such entity, whether by contract or
          otherwise, or (ii) ownership of fifty percent (50%) or more of the
          outstanding shares, or (iii) beneficial ownership of such entity.
    
          "You" (or "Your") shall mean an individual or Legal Entity
          exercising permissions granted by this License.
    
          "Source" form shall mean the preferred form for making modifications,
          including but not limited to software source code, documentation
          source, and configuration files.
    
          "Object" form shall mean any form resulting from mechanical
          transformation or translation of a Source form, including but
          not limited to compiled object code, generated documentation,
          and conversions to other media types.
    
          "Work" shall mean the work of authorship, whether in Source or
          Object form, made available under the License, as indicated by a
          copyright notice that is included in or attached to the work
          (an example is provided in the Appendix below).
    
          "Derivative Works" shall mean any work, whether in Source or Object
          form, that is based on (or derived from) the Work and for which the
          editorial revisions, annotations, elaborations, or other modifications
          represent, as a whole, an original work of authorship. For the purposes
          of this License, Derivative Works shall not include works that remain
          separable from, or merely link (or bind by name) to the interfaces of,
          the Work and Derivative Works thereof.
    
          "Contribution" shall mean any work of authorship, including
          the original version of the Work and any modifications or additions
          to that Work or Derivative Works thereof, that is intentionally
          submitted to Licensor for inclusion in the Work by the copyright owner
          or by an individual or Legal Entity authorized to submit on behalf of
          the copyright owner. For the purposes of this definition, "submitted"
          means any form of electronic, verbal, or written communication sent
          to the Licensor or its representatives, including but not limited to
          communication on electronic mailing lists, source code control systems,
          and issue tracking systems that are managed by, or on behalf of, the
          Licensor for the purpose of discussing and improving the Work, but
          excluding communication that is conspicuously marked or otherwise
          designated in writing by the copyright owner as "Not a Contribution."
    
          "Contributor" shall mean Licensor and any individual or Legal Entity
          on behalf of whom a Contribution has been received by Licensor and
          subsequently incorporated within the Work.
    
       2. Grant of Copyright License. Subject to the terms and conditions of
          this License, each Contributor hereby grants to You a perpetual,
          worldwide, non-exclusive, no-charge, royalty-free, irrevocable
          copyright license to reproduce, prepare Derivative Works of,
          publicly display, publicly perform, sublicense, and distribute the
          Work and such Derivative Works in Source or Object form.
    
       3. Grant of Patent License. Subject to the terms and conditions of
          this License, each Contributor hereby grants to You a perpetual,
          worldwide, non-exclusive, no-charge, royalty-free, irrevocable
          (except as stated in this section) patent license to make, have made,
          use, offer to sell, sell, import, and otherwise transfer the Work,
          where such license applies only to those patent claims licensable
          by such Contributor that are necessarily infringed by their
          Contribution(s) alone or by combination of their Contribution(s)
          with the Work to which such Contribution(s) was submitted. If You
          institute patent litigation against any entity (including a
          cross-claim or counterclaim in a lawsuit) alleging that the Work
          or a Contribution incorporated within the Work constitutes direct
          or contributory patent infringement, then any patent licenses
          granted to You under this License for that Work shall terminate
          as of the date such litigation is filed.
    
       4. Redistribution. You may reproduce and distribute copies of the
          Work or Derivative Works thereof in any medium, with or without
          modifications, and in Source or Object form, provided that You
          meet the following conditions:
    
          (a) You must give any other recipients of the Work or
              Derivative Works a copy of this License; and
    
          (b) You must cause any modified files to carry prominent notices
              stating that You changed the files; and
    
          (c) You must retain, in the Source form of any Derivative Works
              that You distribute, all copyright, patent, trademark, and
              attribution notices from the Source form of the Work,
              excluding those notices that do not pertain to any part of
              the Derivative Works; and
    
          (d) If the Work includes a "NOTICE" text file as part of its
              distribution, then any Derivative Works that You distribute must
              include a readable copy of the attribution notices contained
              within such NOTICE file, excluding those notices that do not
              pertain to any part of the Derivative Works, in at least one
              of the following places: within a NOTICE text file distributed
              as part of the Derivative Works; within the Source form or
              documentation, if provided along with the Derivative Works; or,
              within a display generated by the Derivative Works, if and
              wherever such third-party notices normally appear. The contents
              of the NOTICE file are for informational purposes only and
              do not modify the License. You may add Your own attribution
              notices within Derivative Works that You distribute, alongside
              or as an addendum to the NOTICE text from the Work, provided
              that such additional attribution notices cannot be construed
              as modifying the License.
    
          You may add Your own copyright statement to Your modifications and
          may provide additional or different license terms and conditions
          for use, reproduction, or distribution of Your modifications, or
          for any such Derivative Works as a whole, provided Your use,
          reproduction, and distribution of the Work otherwise complies with
          the conditions stated in this License.
    
       5. Submission of Contributions. Unless You explicitly state otherwise,
          any Contribution intentionally submitted for inclusion in the Work
          by You to the Licensor shall be under the terms and conditions of
          this License, without any additional terms or conditions.
          Notwithstanding the above, nothing herein shall supersede or modify
          the terms of any separate license agreement you may have executed
          with Licensor regarding such Contributions.
    
       6. Trademarks. This License does not grant permission to use the trade
          names, trademarks, service marks, or product names of the Licensor,
          except as required for reasonable and customary use in describing the
          origin of the Work and reproducing the content of the NOTICE file.
    
       7. Disclaimer of Warranty. Unless required by applicable law or
          agreed to in writing, Licensor provides the Work (and each
          Contributor provides its Contributions) on an "AS IS" BASIS,
          WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
          implied, including, without limitation, any warranties or conditions
          of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
          PARTICULAR PURPOSE. You are solely responsible for determining the
          appropriateness of using or redistributing the Work and assume any
          risks associated with Your exercise of permissions under this License.
    
       8. Limitation of Liability. In no event and under no legal theory,
          whether in tort (including negligence), contract, or otherwise,
          unless required by applicable law (such as deliberate and grossly
          negligent acts) or agreed to in writing, shall any Contributor be
          liable to You for damages, including any direct, indirect, special,
          incidental, or consequential damages of any character arising as a
          result of this License or out of the use or inability to use the
          Work (including but not limited to damages for loss of goodwill,
          work stoppage, computer failure or malfunction, or any and all
          other commercial damages or losses), even if such Contributor
          has been advised of the possibility of such damages.
    
       9. Accepting Warranty or Additional Liability. While redistributing
          the Work or Derivative Works thereof, You may choose to offer,
          and charge a fee for, acceptance of support, warranty, indemnity,
          or other liability obligations and/or rights consistent with this
          License. However, in accepting such obligations, You may act only
          on Your own behalf and on Your sole responsibility, not on behalf
          of any other Contributor, and only if You agree to indemnify,
          defend, and hold each Contributor harmless for any liability
          incurred by, or claims asserted against, such Contributor by reason
          of your accepting any such warranty or additional liability.
    
       END OF TERMS AND CONDITIONS
    
       APPENDIX: How to apply the Apache License to your work.
    
          To apply the Apache License to your work, attach the following
          boilerplate notice, with the fields enclosed by brackets "[]"
          replaced with your own identifying information. (Don't include
          the brackets!)  The text should be enclosed in the appropriate
          comment syntax for the file format. We also recommend that a
          file or class name and description of purpose be included on the
          same "printed page" as the copyright notice for easier
          identification within third-party archives.
    
       Copyright [yyyy] [name of copyright owner]
    
       Licensed under the Apache License, Version 2.0 (the "License");
       you may not use this file except in compliance with the License.
       You may obtain a copy of the License at
    
           http://www.apache.org/licenses/LICENSE-2.0
    
       Unless required by applicable law or agreed to in writing, software
       distributed under the License is distributed on an "AS IS" BASIS,
       WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
       See the License for the specific language governing permissions and
       limitations under the License.
    
    """
}

/// One in-flight preview frame; expensive Vision/CI work stays off capture and main queues.
/// Inspired by CainCamera's staged pipeline. Preview resolution is independent of still capture.
final class RealtimePreviewProcessor {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "opa.preview.effects", qos: .userInitiated)
    private var options = PhotoRenderOptions()
    private var enabled = false
    private var sink: ((CGImage?) -> Void)?
    private var inFlight = false
    private var lastFrame = 0.0
    private var generation = 0

    func configure(options: PhotoRenderOptions, enabled: Bool, sink: @escaping (CGImage?) -> Void) {
        lock.lock()
        let changed = self.enabled != enabled || self.options.filter != options.filter || self.options.grade != options.grade || self.options.style != options.style || self.options.beauty != options.beauty || self.options.filterStrength != options.filterStrength
        let wasEnabled = self.enabled
        self.options = options; self.enabled = enabled; self.sink = sink
        if changed && wasEnabled != enabled { generation += 1 }
        lock.unlock()
        if !enabled { sink(nil) }
    }
    func detach() {
        lock.lock(); sink = nil; enabled = false; generation += 1; lock.unlock()
    }
    func consume(_ sample: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let fps = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical ? 8.0 : 15.0
        guard enabled, sink != nil, !inFlight, now - lastFrame >= 1 / fps,
              let buffer = CMSampleBufferGetImageBuffer(sample) else { lock.unlock(); return }
        inFlight = true; lastFrame = now
        let options = self.options
        let generation = self.generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let result: CGImage? = autoreleasepool {
                var image = CIImage(cvPixelBuffer: buffer) // camera output is portrait, unmirrored
                let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                if let beauty = options.beauty { image = PortraitBeautyEngine.shared.processCI(image, settings: beauty) ?? image }
                image = PhotoPostProcessor.applyColor(to: image, options: options)
                return ImagePipeline.context.createCGImage(image, from: image.extent)
            }
            DispatchQueue.main.async {
                self.lock.lock()
                let deliver = self.generation == generation && self.enabled ? self.sink : nil
                self.inFlight = false
                self.lock.unlock()
                deliver?(result)
            }
        }
    }
}
