import Combine
import Foundation
import AVFoundation
import CoreImage
import Vision
import UIKit

struct SubjectInfo: Equatable {
    var type: String = "未知"
    var rect: CGRect = .zero
    var confidence: Float = 0
}

/// 实时分析中枢。
///
/// 相比上一版的改动：
/// - 用"时间门控"代替"每 N 帧"，掉帧时行为一致；
/// - 分类请求 2 Hz，其余请求 10 Hz，UI 发布 5 Hz；
/// - 场景与自动拍摄都加了滞回（连续帧确认），避免抖动；
/// - 构图评分改成 0–100 的可解释分项，自动拍摄阈值与上限对齐；
/// - 把时段（日间/黄金时段/蓝调/夜景）真正注入滤镜、调色和建议。
final class FrameAnalyzer: ObservableObject {
    @Published var directorObservation = DirectorObservation()
    @Published var directorDecision = DirectorDecision()
    @Published var observationTick = 0
    @Published var subject = SubjectInfo()
    @Published var frameAspectRatio: CGFloat = 0.75
    @Published var brightness: Double = 0.5
    @Published var horizonAngle: Double = 0
    @Published var compositionScore: Int = 0
    @Published var detectedScene = "风景"
    @Published var sceneConfidence: Double = 0
    @Published var recommendedFilter: PhotoFilter = .natural
    @Published var autoGrade = ColorGrade()
    @Published var gradeSummary = "自然"
    @Published var framingHint = "等待识别主体"
    @Published var directorTitle = "AI 导演：准备中"
    @Published var directorInstruction = "移动手机寻找主体，保持稳定"
    @Published var lightAdvice = "正在判断光线"
    @Published var recommendedZoom: Double = 1
    @Published var qualityExposure = 0
    @Published var qualityComposition = 0
    @Published var qualitySharpness = 0
    @Published var qualityLevel = "准备中"
    @Published var autoCaptureReady = false
    @Published var autoCaptureHeld = false
    @Published var autoCaptureReason = "等待最佳构图"

    private let analysisQueue = DispatchQueue(label: "opa.analysis", qos: .userInitiated)
    private let stateLock = NSLock()

    private var inFlight = false
    private var lastFast: CFAbsoluteTime = 0
    private var lastClassify: CFAbsoluteTime = 0
    private var lastPublish: CFAbsoluteTime = 0

    private let periodLock = NSLock()
    private var currentPeriod = ""

    // 复用 Vision 请求对象，避免每次分析都重建模型
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let humanRequest: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        return request
    }()
    private let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    private let horizonRequest = VNDetectHorizonRequest()
    private let classifyRequest = VNClassifyImageRequest()
    private var lastLabels: [VNClassificationObservation] = []

    // 滞回状态
    private var sceneCandidate = "风景"
    private var sceneStreak = 0
    private var effectiveScene = "风景"
    private var readinessStreak = 0

    func setPeriod(_ period: String) {
        periodLock.lock()
        currentPeriod = period
        periodLock.unlock()
    }

    // MARK: - 实时帧分析

    func analyze(_ sample: CMSampleBuffer, position: AVCaptureDevice.Position) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        let fastDue = now - lastFast >= 0.10
        let classifyDue = now - lastClassify >= 0.50
        let publishDue = now - lastPublish >= 0.20
        let canRun = !inFlight && fastDue
        if canRun {
            inFlight = true
            lastFast = now
            if classifyDue { lastClassify = now }
            if publishDue { lastPublish = now }
        }
        stateLock.unlock()

        guard canRun else { return }
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.runAnalysis(buffer: buffer, position: position, classify: classifyDue, publish: publishDue)
        }
    }

    private func runAnalysis(buffer: CVPixelBuffer,
                             position: AVCaptureDevice.Position,
                             classify: Bool,
                             publish: Bool) {
        defer {
            stateLock.lock()
            inFlight = false
            stateLock.unlock()
        }

        let brightness = Self.measureBrightness(buffer)
        let sharpness = Self.measureSharpness(buffer)

        let orientation: CGImagePropertyOrientation = .up
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        var requests: [VNImageBasedRequest] = [faceRequest, humanRequest, saliencyRequest, horizonRequest]
        if classify { requests.append(classifyRequest) }
        do { try handler.perform(requests) }
        catch {
            DispatchQueue.main.async {
                self.directorObservation = DirectorObservation()
                self.observationTick += 1
            }
            return
        }

        if classify {
            lastLabels = classifyRequest.results ?? []
        }

        let faces = (faceRequest.results ?? []).filter { $0.confidence >= 0.60 && $0.boundingBox.width * $0.boundingBox.height > 0.002 }
        let humans = (humanRequest.results ?? []).filter { $0.confidence >= 0.60 && $0.boundingBox.width * $0.boundingBox.height > 0.01 }
        let salientObjects = saliencyRequest.results?.first?.salientObjects ?? []
        var info = SubjectInfo()
        var kind = "none"
        let personCount = max(faces.count, humans.count)
        var personConfidence: Double = 0
        if !humans.isEmpty || !faces.isEmpty {
            // Preserve every detected person, and prefer body bounds to a head-only crop.
            let rectangles = humans.map { $0.boundingBox } + faces.map { $0.boundingBox }
            let union = rectangles.dropFirst().reduce(rectangles[0]) { $0.union($1) }
            let confidence = (humans.map { $0.confidence } + faces.map { $0.confidence }).min() ?? 0
            info = SubjectInfo(type: "人物", rect: union, confidence: confidence)
            personConfidence = Double(confidence)
            kind = personCount > 1 ? "group" : humans.isEmpty ? "face" : "body"
        } else if let salient = salientObjects.max(by: { $0.confidence < $1.confidence }) {
            info = SubjectInfo(type: "主体", rect: salient.boundingBox, confidence: salient.confidence)
            kind = "object"
        }

        let horizon = Double(horizonRequest.results?.first?.angle ?? 0)
        let scene = Self.classifyScene(labels: lastLabels, personConfidence: personConfidence)

        // 场景滞回：连续 3 帧同场景才切换，避免 人物/风景 反复跳变
        if scene.name == sceneCandidate {
            sceneStreak += 1
        } else {
            sceneCandidate = scene.name
            sceneStreak = 1
        }
        if sceneStreak >= 3 { effectiveScene = scene.name }
        let sceneConfidence = sceneStreak >= 3 ? scene.confidence : max(0.30, scene.confidence * 0.6)

        let periodLockRef = self.periodLock
        periodLockRef.lock()
        let period = currentPeriod
        periodLockRef.unlock()

        let directorObservation = Self.directorStatistics(buffer, subject: info, kind: kind,
                                                         personCount: personCount, brightness: brightness,
                                                         sharpness: sharpness, horizon: horizon)
        let score = Self.composeScore(subject: info, brightness: brightness, horizon: horizon)
        let filter = PhotoFilter.recommended(scene: effectiveScene, brightness: brightness, period: period)
        let grade = ColorGrade.automatic(scene: effectiveScene,
                                         brightness: brightness,
                                         period: period,
                                         confidence: sceneConfidence)
        let framing = Self.framingHint(subject: info, scene: effectiveScene)
        let exposure = Self.exposureQuality(brightness)
        let level = Self.qualityLevel(exposure: exposure, composition: score, sharpness: sharpness)
        let zoom = Self.recommendedZoom(scene: effectiveScene, subject: info)

        let geometryOK = abs(horizon) < 0.06 && brightness > 0.16 && brightness < 0.88
        let threshold = info.rect == .zero ? 66 : 76
        let readyNow = score >= threshold && geometryOK
        readinessStreak = readyNow ? readinessStreak + 1 : 0
        let ready = readinessStreak >= 3
        let held = score >= max(0, threshold - 4) && abs(horizon) < 0.08 && brightness > 0.14 && brightness < 0.90
        let readyReason = ready ? "最佳构图已锁定，可以拍摄" : "调整角度、水平或光线后再拍"

        guard publish else { return }
        let sceneName = effectiveScene
        let aspectRatio = CGFloat(CVPixelBufferGetWidth(buffer)) / CGFloat(max(1, CVPixelBufferGetHeight(buffer)))

        DispatchQueue.main.async {
            self.subject = info
            self.frameAspectRatio = aspectRatio
            self.brightness = brightness
            self.horizonAngle = horizon
            self.compositionScore = score
            self.detectedScene = sceneName
            self.sceneConfidence = sceneConfidence
            self.recommendedFilter = filter
            self.autoGrade = grade
            self.gradeSummary = Self.gradeSummary(grade, filter: filter)
            self.framingHint = framing
            self.recommendedZoom = zoom
            self.qualityExposure = exposure
            self.qualityComposition = score
            self.qualitySharpness = sharpness
            self.qualityLevel = level
            self.directorTitle = Self.directorTitle(scene: sceneName, score: score)
            self.directorInstruction = Self.directorInstruction(subject: info,
                                                                scene: sceneName,
                                                                horizon: horizon,
                                                                score: score)
            self.lightAdvice = Self.lightAdvice(scene: sceneName, brightness: brightness, period: period)
            self.autoCaptureReady = ready
            self.autoCaptureHeld = held
            self.autoCaptureReason = readyReason
            self.directorObservation = directorObservation
            self.observationTick += 1
        }
    }

    // MARK: - 拍后分析（Review 用）

    func analyzePhoto(_ image: UIImage, completion: @escaping (Double?, Int, Double, SubjectInfo) -> Void) {
        guard let cgImage = image.cgImage else {
            completion(nil, 0, 0, SubjectInfo())
            return
        }
        let orientation = Self.cgOrientation(image.imageOrientation)
        analysisQueue.async {
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            let faceRequest = VNDetectFaceRectanglesRequest()
            let humanRequest = VNDetectHumanRectanglesRequest()
            humanRequest.upperBodyOnly = false
            let horizonRequest = VNDetectHorizonRequest()
            var requests: [VNRequest] = [faceRequest, humanRequest, horizonRequest]

            var aestheticsRequest: VNRequest?
            if #available(iOS 18.0, *) {
                let request = VNCalculateImageAestheticsScoresRequest()
                aestheticsRequest = request
                requests.append(request)
            }
            try? handler.perform(requests)

            let faces = faceRequest.results ?? []
            let humans = humanRequest.results ?? []
            var info = SubjectInfo()
            if let face = faces.max(by: { $0.confidence < $1.confidence }) {
                info = SubjectInfo(type: "人物", rect: face.boundingBox, confidence: face.confidence)
            } else if let human = humans.max(by: { $0.confidence < $1.confidence }) {
                info = SubjectInfo(type: "人物", rect: human.boundingBox, confidence: human.confidence)
            }

            let brightness = Self.measureImageBrightness(cgImage)
            let horizon = Double(horizonRequest.results?.first?.angle ?? 0)
            var aesthetics: Float?
            if #available(iOS 18.0, *),
               let request = aestheticsRequest as? VNCalculateImageAestheticsScoresRequest {
                aesthetics = request.results?.first?.overallScore
            }
            let score = Self.composeScore(subject: info, brightness: brightness, horizon: horizon)
            let aestheticValue = aesthetics.map { Double($0) }
            completion(aestheticValue, score, horizon, info)
        }
    }

    // MARK: - 场景识别

    private static func classifyScene(labels: [VNClassificationObservation],
                                      personConfidence: Double) -> (name: String, confidence: Double) {
        if personConfidence >= 0.35 {
            return ("人物", max(0.65, min(0.99, personConfidence)))
        }
        let candidates: [(String, [String])] = [
            ("海边", ["beach", "coast", "seashore", "ocean", "shoreline"]),
            ("日落", ["sunset", "sunrise", "dusk", "twilight"]),
            ("建筑", ["building", "architecture", "skyscraper", "church", "tower"]),
            ("夜景", ["night", "nighttime", "nightscape"]),
            ("花草", ["flower", "garden", "plant", "vegetation", "blossom"]),
            ("汽车", ["car", "vehicle", "automobile", "truck"]),
            ("风景", ["landscape", "mountain", "valley", "forest", "nature", "sky", "cloud"])
        ]
        var best: (String, Double) = ("风景", 0.30)
        for (scene, keys) in candidates {
            let matches = labels.filter { observation in
                observation.confidence >= 0.12 &&
                keys.contains { observation.identifier.localizedCaseInsensitiveContains($0) }
            }
            guard let match = matches.max(by: { $0.confidence < $1.confidence }) else { continue }
            let value = Double(match.confidence)
            if value > best.1 { best = (scene, value) }
        }
        return best
    }

    // MARK: - 构图评分（0–100，可解释）

    static func composeScore(subject: SubjectInfo, brightness: Double, horizon: Double) -> Int {
        var score = 0.0

        if subject.rect != .zero {
            let midX = Double(subject.rect.midX)
            let midY = Double(subject.rect.midY)
            let spatial = DirectorCropImportance.score(x: midX, y: midY, ruleOfThirds: subject.type != "人物")
            score += 40 * min(1, max(0, spatial / 1.41))

            let inset = Double(min(subject.rect.minX,
                                   subject.rect.minY,
                                   1 - subject.rect.maxX,
                                   1 - subject.rect.maxY))
            score += 15 * min(1, max(0, inset / 0.08))
        } else {
            score += 27   // 无主体：拿不到三分位置与留白分，只保留基础分
        }

        score += 25 * max(0, 1 - abs(horizon) / 0.12)
        score += 20 * max(0, 1 - abs(brightness - 0.52) / 0.28)
        return max(0, min(100, Int(score.rounded())))
    }

    // MARK: - 文案与质量分

    private static func framingHint(subject: SubjectInfo, scene: String) -> String {
        guard subject.rect != .zero else {
            return scene == "风景" ? "寻找前景层次，避免主体贴边" : "等待识别主体"
        }
        let x = subject.rect.midX
        if x < 0.30 { return "主体偏左：右侧保留视线空间" }
        if x > 0.70 { return "主体偏右：左侧保留视线空间" }
        if abs(x - 0.5) < 0.10 { return "主体居中：尝试向三分线移动" }
        return "主体位置合适，保持当前取景"
    }

    private static func gradeSummary(_ grade: ColorGrade, filter: PhotoFilter) -> String {
        var parts = [filter.rawValue]
        if grade.temperature > 5 { parts.append("偏暖") } else if grade.temperature < -5 { parts.append("偏冷") }
        if grade.saturation > 1.07 { parts.append("高彩") } else if grade.saturation < 0.98 { parts.append("低彩") }
        if grade.contrast > 1.06 { parts.append("高反差") }
        if grade.highlights < -8 { parts.append("压高光") }
        if grade.shadows > 6 { parts.append("提阴影") }
        return parts.joined(separator: " · ")
    }

    private static func recommendedZoom(scene: String, subject: SubjectInfo) -> Double {
        if subject.rect != .zero { return 1 }
        if scene == "建筑" { return 0.5 }
        return 1
    }

    private static func exposureQuality(_ brightness: Double) -> Int {
        if brightness < 0.10 || brightness > 0.95 { return 40 }
        if brightness < 0.16 || brightness > 0.90 { return 62 }
        if brightness < 0.22 || brightness > 0.85 { return 80 }
        return 100
    }

    private static func qualityLevel(exposure: Int, composition: Int, sharpness: Int) -> String {
        let average = (exposure + composition + sharpness) / 3
        if average >= 85 { return "优秀" }
        if average >= 70 { return "良好" }
        return "需要调整"
    }

    private static func directorTitle(scene: String, score: Int) -> String {
        if score >= 88 { return "AI 导演：黄金构图" }
        switch scene {
        case "人物", "自拍": return "AI 导演：人像构图"
        case "日落": return "AI 导演：晚霞构图"
        case "建筑": return "AI 导演：建筑透视"
        case "夜景": return "AI 导演：夜景稳定"
        default: return "AI 导演：寻找最佳构图"
        }
    }

    private static func directorInstruction(subject: SubjectInfo, scene: String, horizon: Double, score: Int) -> String {
        if abs(horizon) > 0.06 { return "左右旋转手机，先把水平线校正" }
        guard subject.rect != .zero else {
            return scene == "风景" ? "向前后移动，寻找前景 + 中景 + 远景的层次" : "继续移动取景，等待主体进入黄金区域"
        }
        let x = subject.rect.midX
        if x < 0.32 { return "向左移动一点，让主体进入左侧三分线" }
        if x > 0.68 { return "向右移动一点，让主体进入右侧三分线" }
        if score < 78 { return "上下轻微移动，减少边缘杂物并增加留白" }
        return "保持当前位置，手机稳定 0.5 秒"
    }

    private static func lightAdvice(scene: String, brightness: Double, period: String) -> String {
        if brightness < 0.14 { return "暗光：优先 1×，保持稳定，避免数字变焦" }
        if brightness > 0.90 { return "高光：压低曝光，避免天空细节丢失" }
        if period == "黄金时段" { return "黄金时段：侧逆光最出层次，注意保护高光" }
        if period == "蓝调时刻" { return "蓝调时刻：天空色温很冷，适合人物 + 城市灯光" }
        if scene == "人物" { return "人像：优先侧前方柔光，避免正午顶光" }
        if scene == "日落" { return "逆光：保留太阳附近高光，主体不要完全剪影" }
        return "光线均衡：保持主体与背景层次"
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
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

    // MARK: - 像素统计

    private static func directorStatistics(_ buffer: CVPixelBuffer, subject: SubjectInfo,
                                           kind: String, personCount: Int, brightness: Double,
                                           sharpness: Int, horizon: Double) -> DirectorObservation {
        var result = DirectorObservation()
        if subject.rect != .zero {
            let b = subject.rect
            result.subject = DirectorBox(x: Double(b.minX), y: Double(b.minY), width: Double(b.width), height: Double(b.height))
        }
        result.subjectKind = kind
        result.personCount = personCount
        result.confidence = Double(subject.confidence)
        result.brightness = brightness; result.sharpness = sharpness; result.horizon = horizon
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return result }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return result }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let strideBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, strideBytes >= width * 4 else { return result }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var n = 0.0, high = 0.0, low = 0.0, sat = 0.0, warm = 0.0
        var left = 0.0, right = 0.0, leftN = 0.0, rightN = 0.0, subjectY = 0.0, subjectN = 0.0
        for y in stride(from: 0, to: height, by: max(1, height / 32)) {
            for x in stride(from: 0, to: width, by: max(1, width / 32)) {
                let i = y * strideBytes + x * 4
                let b = Double(bytes[i]) / 255, g = Double(bytes[i + 1]) / 255, r = Double(bytes[i + 2]) / 255
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                high += luma >= 0.96 ? 1 : 0; low += luma <= 0.08 ? 1 : 0
                sat += mx > 0 ? (mx - mn) / mx : 0; warm += r - b; n += 1
                if x < width / 2 { left += luma; leftN += 1 } else { right += luma; rightN += 1 }
                if subject.rect.contains(CGPoint(x: Double(x) / Double(width), y: 1 - Double(y) / Double(height))) {
                    subjectY += luma; subjectN += 1
                }
            }
        }
        result.highlights = high / max(1, n); result.shadows = low / max(1, n)
        result.saturation = sat / max(1, n); result.warmth = warm / max(1, n)
        result.leftBrightness = left / max(1, leftN); result.rightBrightness = right / max(1, rightN)
        result.subjectBrightness = subjectN > 0 ? subjectY / subjectN : brightness
        return result
    }

    private static func measureBrightness(_ buffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return 0.5 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0.5 }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let widthBytes = width * 4
        guard bytesPerRow >= widthBytes else { return 0.5 }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let stepX = max(1, width / 24)
        let stepY = max(1, height / 24)
        let centerX = Double(width) * 0.5
        let centerY = Double(height) * 0.5
        let radius = max(1.0, min(centerX, centerY))

        var total = 0.0
        var weightTotal = 0.0
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let index = y * bytesPerRow + x * 4
                let blue = Double(ptr[index])
                let green = Double(ptr[index + 1])
                let red = Double(ptr[index + 2])
                let luma = (0.0722 * blue + 0.7152 * green + 0.2126 * red) / 255.0
                let distance = hypot(Double(x) - centerX, Double(y) - centerY) / radius
                let weight = max(0.25, 1.0 - distance * 0.55)
                total += luma * weight
                weightTotal += weight
            }
        }
        return weightTotal > 0 ? total / weightTotal : 0.5
    }

    private static func measureSharpness(_ buffer: CVPixelBuffer) -> Int {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return 60 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 60 }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard bytesPerRow >= width * 4 else { return 60 }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let stepX = max(2, width / 48)
        let stepY = max(2, height / 48)
        guard width > stepX * 2, height > stepY * 2 else { return 60 }

        func luma(_ px: Int, _ py: Int) -> Double {
            let index = py * bytesPerRow + px * 4
            return (0.2126 * Double(ptr[index + 2]) + 0.7152 * Double(ptr[index + 1]) + 0.0722 * Double(ptr[index])) / 255.0
        }

        var sum = 0.0
        var count = 0.0
        for y in stride(from: stepY, to: height - stepY, by: stepY) {
            for x in stride(from: stepX, to: width - stepX, by: stepX) {
                let gx = luma(x + stepX, y) - luma(x - stepX, y)
                let gy = luma(x, y + stepY) - luma(x, y - stepY)
                sum += min(1.0, hypot(gx, gy) * 2.8)
                count += 1
            }
        }
        guard count > 0 else { return 60 }
        let normalized = sum / count
        return max(20, min(100, Int((normalized * 150.0 + 55.0).rounded())))
    }

    private static func measureImageBrightness(_ image: CGImage) -> Double {
        let ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0.5 }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: extent.minX, y: extent.minY, z: extent.width, w: extent.height),
                        forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return 0.5 }

        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ImagePipeline.context.render(output,
                                         toBitmap: baseAddress,
                                         rowBytes: 4,
                                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                         format: .RGBA8,
                                         colorSpace: nil)
        }
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255.0
    }
}
