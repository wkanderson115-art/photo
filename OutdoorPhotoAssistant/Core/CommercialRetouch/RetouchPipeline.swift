import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO
import UniformTypeIdentifiers

/// Result of one commercial retouch pass.
struct RetouchOutcome {
    var image: UIImage
    var report: RetouchQualityReport
    var spotsFound: Int
    var spotsRemaining: Int
    var look: RetouchLook
    var exposureEV: Double
}

/// Legacy assessment shape kept for older call sites.
struct RetouchAssessment {
    let acceptable: Bool
    let notes: [String]
}

/// On-device commercial retouch pipeline (V16).
///
/// Stage order mirrors `tools/retouch_lab/pipeline.py`, which is the reference
/// implementation the parameters and QC thresholds were validated against:
/// analyse -> detect blemishes -> heal -> frequency separation -> dodge & burn
/// -> eyes / under-eye / teeth / lips -> tone -> 3D LUT grade -> finishing ->
/// QC gate (automatic repair loop).
final class RetouchPipeline {
    private let context: CIContext
    private let analyzer = RetouchAnalyzer()
    private let engine: RetouchEngine
    private let gate = RetouchQualityGate()
    private lazy var reshapeEngine = RetouchReshapeEngine(context: context)
    private lazy var backgroundEngine = RetouchBackgroundEngine(context: context)

    init() {
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        context = ctx
        engine = RetouchEngine(context: ctx)
    }

    // MARK: - Preset suggestion

    func suggestPreset(image: UIImage) async -> (RetouchPreset, String) {
        let fallback = RetouchPresetCatalog.find("p25")
        guard let cg = image.cgImage else { return (fallback, "无法识别，采用自然风光预设") }
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: cg,
                                      orientation: CGImagePropertyOrientation(rawValue: UInt32(RetouchSpecialist.exifOrientation(image.imageOrientation))) ?? .up)
                .perform([request])
            let labels = (request.results ?? []).filter { $0.confidence >= 0.20 }
            let all = labels.map { $0.identifier.lowercased() }.joined(separator: " ")
            let target = Self.sceneTarget(from: all)
            let preset = RetouchPresetCatalog.all.first { $0.name == target } ?? fallback
            return (preset, labels.first.map { "Vision 初步识别：\($0.identifier)（置信度 \(Int($0.confidence * 100))%），建议人工确认预设" }
                    ?? "未找到可靠分类，建议人工确认预设")
        } catch {
            return (fallback, "场景识别失败，采用自然风光预设")
        }
    }

    /// 20 类场景路由：Vision 标签 → 预设名。顺序敏感，先命中先赢（越具体的场景越靠前），
    /// 这样「人 + 婚纱」不会落到人像、「宠物 + 草地」不会落到风光。
    private static let sceneRules: [(keywords: [String], target: String)] = [
        (["wedding", "bride", "groom", "bouquet"], "浪漫婚纱"),
        (["newborn", "infant", "baby"], "新生儿柔光"),
        (["child", "kid", "toddler", "children"], "儿童抓拍"),
        (["family"], "家庭合影"),
        (["cat", "dog", "pet", "kitten", "puppy", "rabbit", "hamster"], "宠物写真"),
        (["wildlife", "bird", "elephant", "lion", "tiger", "deer"], "野生动物"),
        (["fashion", "runway", "couture", "model"], "时尚大片"),
        (["concert", "stage", "performance", "band", "dj"], "演唱会"),
        (["sport", "running", "bicycle", "soccer", "basketball", "swim"], "高速抓拍"),
        (["food", "dish", "cuisine", "dessert", "coffee", "cake"], "美食写真"),
        (["car", "vehicle", "motorcycle", "automobile", "truck"], "汽车商业"),
        (["building", "architecture", "skyscraper", "interior", "room"], "建筑外观"),
        (["product", "still life", "bottle", "watch", "jewelry"], "静物质感"),
        (["flower", "plant", "leaf", "garden", "blossom"], "花卉微距"),
        (["insect", "butterfly", "bug", "macro"], "昆虫微距"),
        (["star", "night sky", "milky", "aurora", "astronomy", "galaxy"], "银河星空"),
        (["aerial", "drone", "bird's eye", "top down"], "自然航拍"),
        (["underwater", "coral", "diving", "aquarium"], "海底风光"),
        (["document", "text", "receipt", "book", "paper", "screenshot"], "文档扫描"),
        (["portrait", "person", "face", "selfie", "people"], "商业自然"),
        (["travel", "vacation", "tourist"], "旅行大片"),
        (["city", "skyline", "urban", "downtown", "street"], "城市纪实"),
        (["landscape", "mountain", "sky", "beach", "forest", "sunset", "lake", "cloud"], "自然风光"),
    ]

    /// Deterministic label → preset routing; unknown labels fall back to 自然风光.
    static func sceneTarget(from labels: String) -> String {
        for rule in sceneRules where rule.keywords.contains(where: { labels.contains($0) }) {
            return rule.target
        }
        return "自然风光"
    }

    // MARK: - Processing

    func process(_ image: UIImage, preset: RetouchPreset, strength: Double = 1.0) throws -> RetouchOutcome {
        guard let raw = image.cgImage else { throw RetouchFailure.invalidImage }
        let input = CIImage(cgImage: raw).oriented(forExifOrientation: RetouchSpecialist.exifOrientation(image.imageOrientation))
        let extent = input.extent
        guard extent.width > 8, extent.height > 8 else { throw RetouchFailure.invalidImage }
        guard let plan = LocalRetouchPreflight.inspect(width: Int(extent.width), height: Int(extent.height)) else {
            throw RetouchFailure.invalidImage
        }

        var parameters = preset.parameters.scaled(longEdge: max(extent.width, extent.height))
        parameters = Self.applying(strength: strength, to: parameters)

        let geometry = analyzer.detectFace(in: input, context: context)
        var analysis: SkinAnalysis?
        if let geometry, let result = analyzer.analyze(image: input, geometry: geometry, context: context) {
            analysis = result
        }

        var passes = 0
        var best: (image: CIImage, report: RetouchQualityReport, spots: Int, remaining: Int, ev: Double) = (input, .failure, 0, 0, 0)
        repeat {
            passes += 1
            let (rendered, report, spots, remaining, ev) = renderPass(input: input, analysis: analysis,
                                                                       parameters: parameters, preset: preset)
            best = (rendered, report, spots, remaining, ev)
            if report.passed || passes >= max(1, parameters.maxPasses) { break }
            // automatic repair: back off whichever stage the gate rejected
            if (report.metrics["texture_retention"] ?? 1) < 0.50 {
                parameters.smoothAmount *= 0.72
                parameters.textureGain = min(1.0, parameters.textureGain + 0.06)
            } else if (report.metrics["clipping_skin"] ?? 0) > 0.002 || (report.metrics["clipping_full"] ?? 0) > 0.01 {
                parameters.exposureTarget -= 0.02
                parameters.highlightRolloff = max(0.72, parameters.highlightRolloff - 0.03)
            } else if abs((report.metrics["seam_ratio"] ?? 1) - 1.0) > 0.30 {
                parameters.dodgeBurnAmount *= 0.7
                parameters.smoothAmount *= 0.85
            } else {
                break
            }
        } while true

        guard let cg = LocalTiledRenderer.render(best.image, extent: extent, context: context,
                                                 tileEdge: plan.tier == .standard ? 2048 : 1024) else {
            throw RetouchFailure.processingFailed
        }
        let output = UIImage(cgImage: cg, scale: 1, orientation: .up)
        return RetouchOutcome(image: output, report: best.report, spotsFound: best.spots,
                              spotsRemaining: best.remaining, look: preset.look, exposureEV: best.ev)
    }

    private func renderPass(input: CIImage, analysis: SkinAnalysis?, parameters: RetouchParameters,
                            preset: RetouchPreset) -> (CIImage, RetouchQualityReport, Int, Int, Double) {
        var work = input
        var spots: [BlemishSpot] = []
        if let analysis {
            let detection = engine.detectSpots(in: input, analysis: analysis, parameters: parameters)
            spots = detection.spots
            if !spots.isEmpty {
                work = engine.heal(work, spots: spots, proxy: detection.proxy, parameters: parameters)
            }
            work = engine.smoothSkin(work, analysis: analysis, parameters: parameters)
            work = engine.dodgeAndBurn(work, analysis: analysis, parameters: parameters)
            work = engine.eyes(work, analysis: analysis, parameters: parameters)
            work = engine.underEye(work, analysis: analysis, parameters: parameters)
            work = engine.teeth(work, analysis: analysis, parameters: parameters)
            work = engine.lips(work, analysis: analysis, parameters: parameters)
        }
        let (toned, ev) = engine.tone(work, analysis: analysis, parameters: parameters)
        work = toned
        work = engine.grade(work, look: preset.look, parameters: parameters)
        work = engine.finish(work, analysis: analysis, parameters: parameters)
        work = work.cropped(to: input.extent)

        let remaining: Int
        if let analysis {
            remaining = engine.detectSpots(in: work, analysis: analysis, parameters: parameters).spots.count
        } else {
            remaining = 0
        }
        let clearance: Double
        if spots.isEmpty {
            clearance = 1.0
        } else {
            clearance = max(0.0, min(1.0, 1.0 - Double(remaining) / Double(spots.count)))
        }
        let report: RetouchQualityReport
        if let analysis {
            report = gate.review(RetouchQualityGate.Input(original: input,
                                                          candidate: work,
                                                          skinMask: analysis.skinMask,
                                                          blemishClearance: clearance,
                                                          spotsBefore: spots.count,
                                                          exposureEV: ev,
                                                          whiteBalance: analysis.whiteBalance,
                                                          context: context))
        } else {
            report = gate.review(RetouchQualityGate.Input(original: input,
                                                          candidate: work,
                                                          skinMask: nil,
                                                          blemishClearance: 1.0,
                                                          spotsBefore: 0,
                                                          exposureEV: ev,
                                                          whiteBalance: SIMD3(1, 1, 1),
                                                          context: context))
        }
        return (work, report, spots.count, remaining, ev)
    }

    static func applying(strength: Double, to parameters: RetouchParameters) -> RetouchParameters {
        let s = min(max(strength, 0.4), 1.3)
        var p = parameters
        p.smoothAmount *= s
        p.dodgeBurnAmount *= s
        p.blemishStrength = min(1.0, p.blemishStrength * s)
        p.eyeAmount *= s
        p.underEyeAmount *= s
        p.teethAmount *= s
        p.lipAmount *= s
        p.clarityAmount *= s
        p.sharpenAmount *= s
        p.lutStrength *= min(s, 1.15)
        p.vibrance *= s
        return p
    }

    // MARK: - Batch / studio API

    /// Analysis only (used once per frame to build the shoot anchor).
    func analysis(for image: UIImage) -> SkinAnalysis? {
        guard let raw = image.cgImage else { return nil }
        let input = CIImage(cgImage: raw)
            .oriented(forExifOrientation: RetouchSpecialist.exifOrientation(image.imageOrientation))
        guard let geometry = analyzer.detectFace(in: input, context: context) else { return nil }
        return analyzer.analyze(image: input, geometry: geometry, context: context)
    }

    /// Full studio pass: retouch -> tone -> grade -> liquify -> background ->
    /// finishing -> optional ID-photo crop, all against the shoot anchor so a
    /// delivered set stays colour-consistent.
    func process(_ image: UIImage, preset: RetouchPreset,
                 adjustments: RetouchAdjustments, anchor: ShootAnchor?) throws -> RetouchOutcome {
        guard let raw = image.cgImage else { throw RetouchFailure.invalidImage }
        let input = CIImage(cgImage: raw)
            .oriented(forExifOrientation: RetouchSpecialist.exifOrientation(image.imageOrientation))
        let extent = input.extent
        guard extent.width > 8, extent.height > 8,
              let plan = LocalRetouchPreflight.inspect(width: Int(extent.width), height: Int(extent.height)) else {
            throw RetouchFailure.invalidImage
        }
        var parameters = preset.parameters.scaled(longEdge: max(extent.width, extent.height))
        parameters = Self.applying(strength: adjustments.strength, to: parameters)

        var geometry: FaceGeometry?
        var analysis: SkinAnalysis?
        if let detected = analyzer.detectFace(in: input, context: context) {
            geometry = detected
            analysis = analyzer.analyze(image: input, geometry: detected, context: context)
        }

        var work = input
        var appliedEV = 0.0
        if let anchor, let analysis {
            let fix = anchor.correction(for: analysis)
            work = engine.applyCorrection(work, gains: fix.gains, ev: fix.ev)
            appliedEV += fix.ev
        }

        var spots: [BlemishSpot] = []
        if let analysis {
            let detection = engine.detectSpots(in: work, analysis: analysis, parameters: parameters)
            spots = detection.spots
            if !spots.isEmpty {
                work = engine.heal(work, spots: spots, proxy: detection.proxy, parameters: parameters)
            }
            work = engine.smoothSkin(work, analysis: analysis, parameters: parameters)
            work = engine.dodgeAndBurn(work, analysis: analysis, parameters: parameters)
            work = engine.eyes(work, analysis: analysis, parameters: parameters)
            work = engine.underEye(work, analysis: analysis, parameters: parameters)
            work = engine.teeth(work, analysis: analysis, parameters: parameters)
            work = engine.lips(work, analysis: analysis, parameters: parameters)
        }
        // anchored runs must not re-normalise: the anchor already set WB/exposure
        let (toned, toneEV) = engine.tone(work, analysis: analysis, parameters: parameters,
                                          applyWhiteBalance: anchor == nil,
                                          skipExposure: anchor != nil)
        work = toned
        appliedEV += toneEV
        work = engine.grade(work, look: preset.look, parameters: parameters)
        work = engine.finish(work, analysis: analysis, parameters: parameters)
        work = work.cropped(to: extent)

        // QC runs on the retouch itself, before liquify / background work:
        // those two are parameter edits the operator reviews by eye, and a cutout
        // would otherwise fail the structural metrics by design.
        var report = RetouchQualityReport(
            passed: false, metrics: [:],
            notes: ["未检测到可用人脸：已执行全图色调与风格精修，肤质质检跳过，请人工复核成片"])
        if let analysis {
            let remaining = engine.detectSpots(in: work, analysis: analysis, parameters: parameters).spots.count
            let clearance = spots.isEmpty ? 1.0 : max(0.0, min(1.0, 1.0 - Double(remaining) / Double(spots.count)))
            report = gate.review(RetouchQualityGate.Input(original: input, candidate: work,
                                                          skinMask: analysis.skinMask,
                                                          blemishClearance: clearance,
                                                          spotsBefore: spots.count,
                                                          exposureEV: appliedEV,
                                                          whiteBalance: analysis.whiteBalance,
                                                          context: context))
        }

        let portraitPreset = ["人像摄影", "婚纱与情侣", "家庭与儿童", "时尚与穿搭"].contains(preset.category)
        if portraitPreset && !adjustments.reshape.isNeutral {
            work = reshapeEngine.apply(work, geometry: geometry, parameters: adjustments.reshape)
            applyStudioNote(&report, "已液化：需目视复核脸型与背景边缘")
        }
        if !adjustments.background.isKeep {
            let mask = backgroundEngine.subjectMask(for: work, geometry: geometry, context: context)
            work = backgroundEngine.apply(work, subjectMask: mask, options: adjustments.background)
            applyStudioNote(&report, "已换底/清理背景：需目视复核发丝边缘")
        }
        if adjustments.cropToIDPhoto, let spec = adjustments.idPhoto {
            if let cropped = backgroundEngine.idPhoto(work, geometry: geometry, spec: spec,
                                                      background: adjustments.background, dpi: 300) {
                work = cropped
                applyStudioNote(&report, "已按证件照规格裁切（\(spec.displayName)）")
            }
        }

        let outputExtent = work.extent
        guard let cg = LocalTiledRenderer.render(work, extent: outputExtent, context: context,
                                                 tileEdge: plan.tier == .standard ? 2048 : 1024) else {
            throw RetouchFailure.processingFailed
        }
        let output = UIImage(cgImage: cg, scale: 1, orientation: .up)
        return RetouchOutcome(image: output, report: report, spotsFound: spots.count,
                              spotsRemaining: 0, look: preset.look, exposureEV: appliedEV)
    }

    private func applyStudioNote(_ report: inout RetouchQualityReport, _ note: String) {
        if !report.notes.contains(note) { report.notes.append(note) }
    }

    // MARK: - Manual repair

    /// User-driven spot repair on the current version. The point is normalised in
    /// displayed image space; the engine picks a clean source patch automatically.
    func healSpot(_ image: UIImage, at point: CGPoint) throws -> UIImage {
        guard let cg = image.cgImage, (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw RetouchFailure.invalidImage
        }
        let input = CIImage(cgImage: cg)
        let extent = input.extent
        guard let geometry = analyzer.detectFace(in: input, context: context),
              let analysis = analyzer.analyze(image: input, geometry: geometry, context: context) else {
            throw RetouchFailure.processingFailed
        }
        var parameters = RetouchParameters().scaled(longEdge: max(extent.width, extent.height))
        parameters.blemishSensitivity = 1.0
        let detection = engine.detectSpots(in: input, analysis: analysis, parameters: parameters)
        // the UI passes a top-left normalised point; spots use the same convention
        let manual = BlemishSpot(center: CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1)),
                                 radius: max(0.004, min(0.02, 6.0 / max(extent.width, extent.height))),
                                 score: 1.0, kind: "manual")
        let healed = engine.heal(input, spots: [manual] + detection.spots, proxy: detection.proxy, parameters: parameters)
        guard let rendered = LocalTiledRenderer.render(healed, extent: extent, context: context, tileEdge: 2048) else {
            throw RetouchFailure.processingFailed
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    // MARK: - Legacy assessment

    func assess(original: UIImage, result: UIImage) -> RetouchAssessment {
        guard let source = original.cgImage, let output = result.cgImage else {
            return RetouchAssessment(acceptable: false, notes: ["无法读取图像像素，拒绝自动验收"])
        }
        let normalized = CIImage(cgImage: source)
            .oriented(forExifOrientation: RetouchSpecialist.exifOrientation(original.imageOrientation))
        let report = gate.review(RetouchQualityGate.Input(original: normalized,
                                                          candidate: CIImage(cgImage: output),
                                                          skinMask: nil,
                                                          blemishClearance: 1.0,
                                                          spotsBefore: 0,
                                                          exposureEV: 0,
                                                          whiteBalance: SIMD3(1, 1, 1),
                                                          context: context))
        return RetouchAssessment(acceptable: report.passed, notes: report.notes)
    }
}

enum RetouchFailure: LocalizedError {
    case invalidImage, processingFailed, invalidExport
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "图片无法解码"
        case .processingFailed: return "本地图像处理失败"
        case .invalidExport: return "JPEG 导出验证失败"
        }
    }
}

/// Versioned files in Application Support. Original bytes are copied and never overwritten.
final class RetouchVersionStore {
    private let fm = FileManager.default
    private var root: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CommercialRetouch", isDirectory: true)
    }

    func newJob(originalData: Data) throws -> UUID {
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try originalData.write(to: folder.appendingPathComponent("original.bin"), options: .atomic)
        return id
    }

    func versions(job: UUID) -> [URL] {
        let folder = root.appendingPathComponent(job.uuidString, isDirectory: true)
        return ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { ["local", "seedream", "fusion"].contains($0.lastPathComponent.components(separatedBy: "-").first ?? "")
                && $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func originalBytes(job: UUID) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(job.uuidString, isDirectory: true)
            .appendingPathComponent("original.bin"))
    }

    func verifyOriginal(job: UUID, expected: Data) -> Bool {
        (try? originalBytes(job: job)) == expected
    }

    func saveJPEG(_ image: UIImage, job: UUID, label: String) throws -> URL {
        guard ["local", "seedream", "fusion"].contains(label) else { throw RetouchFailure.invalidExport }
        let folder = root.appendingPathComponent(job.uuidString, isDirectory: true)
        let temporary = folder.appendingPathComponent("\(label)-\(UUID().uuidString).tmp")
        guard let cg = image.cgImage else { throw RetouchFailure.invalidExport }
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let normalized = CIContext().createCGImage(CIImage(cgImage: cg),
                                                   from: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
                                                   format: .RGBA8, colorSpace: rgb) ?? cg
        guard let destinationRef = CGImageDestinationCreateWithURL(temporary as CFURL,
                                                                   UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RetouchFailure.invalidExport
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95,
                                            kCGImagePropertyOrientation: 1]
        CGImageDestinationAddImage(destinationRef, normalized, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef),
              let check = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceCreateImageAtIndex(check, 0, nil) != nil else { throw RetouchFailure.invalidExport }
        // Every run creates a new revision; never replace a previous successful version.
        let revision = folder.appendingPathComponent("\(label)-\(UUID().uuidString).jpg")
        try fm.moveItem(at: temporary, to: revision)
        let report = CommercialQualityGate().verifyJPEG(revision, expectedWidth: cg.width, expectedHeight: cg.height)
        if report.decision == .rejected {
            try? fm.removeItem(at: revision)
            throw RetouchFailure.invalidExport
        }
        try RetouchRecovery().record(job: job, url: revision, kind: label, needsHumanReview: label != "local")
        return revision
    }
}
