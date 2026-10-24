import Foundation

// Frame evidence is expressed in normalized Vision coordinates (origin bottom-left).
// No image bytes, face identities or biometric templates are stored in preferences.
struct DirectorBox: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var area: Double { max(0, width) * max(0, height) }
    var valid: Bool { [x, y, width, height].allSatisfy { $0.isFinite } && width > 0 && height > 0 }
    func scaledAroundCenter(_ factor: Double) -> DirectorBox {
        DirectorBox(x: 0.5 + (x - 0.5) * factor, y: 0.5 + (y - 0.5) * factor,
                    width: width * factor, height: height * factor)
    }
    func overlap(_ other: DirectorBox) -> Double {
        let w = max(0, min(maxX, other.maxX) - max(x, other.x))
        let h = max(0, min(maxY, other.maxY) - max(y, other.y))
        let intersection = w * h
        return intersection / max(0.000001, area + other.area - intersection)
    }
}

struct DirectorObservation: Equatable {
    var subject: DirectorBox?
    var subjectKind = "none" // body / face / group / object / none
    var personCount = 0
    var confidence = 0.0
    var brightness = 0.5
    var highlights = 0.0
    var shadows = 0.0
    var saturation = 0.0
    var warmth = 0.0 // sampled red minus blue, not calibrated color temperature
    var subjectBrightness = 0.5
    var leftBrightness = 0.5
    var rightBrightness = 0.5
    var sharpness = 60
    var horizon = 0.0
}

struct DirectorEvidence: Equatable {
    let domain: String
    let rule: String
    let observation: String
    let action: String
}

struct DirectorLearningContext: Codable, Equatable {
    var scene: String
    var kind: String
    var group: Bool
    var subjectFraction: Double
    var automaticFraming: Bool
    var key: String { scene + "/" + kind + (group ? "/group" : "/single") }
}

struct DirectorPreference: Codable, Equatable {
    var count = 0
    var occupancySamples = 0
    var filterSamples = 0
    var subjectFraction = 0.5
    var filterStrength = 0.55
    var preferredFilter = "自然"
    var filterVotes: [String: Int] = [:]

    /// Bounded online preference update; does not retrain the Vision models.
    mutating func learn(context: DirectorLearningContext, filter: String, strength: Double,
                        framingFeedback: String) {
        let alpha = 0.18
        if context.automaticFraming && context.subjectFraction.isFinite && context.subjectFraction > 0 {
            let multiplier = framingFeedback == "主体太小" ? 1.10 : framingFeedback == "主体太大" ? 0.90 : 1
            let observed = max(0.08, min(0.82, context.subjectFraction * multiplier))
            subjectFraction = occupancySamples == 0 ? observed : subjectFraction * (1 - alpha) + observed * alpha
            occupancySamples += 1
        }
        if framingFeedback == "喜欢效果" {
            let safeStrength = strength.isFinite ? max(0, min(0.8, strength)) : 0.55
            filterStrength = filterSamples == 0 ? safeStrength : filterStrength * (1 - alpha) + safeStrength * alpha
            filterVotes[filter, default: 0] += 1
            preferredFilter = filterVotes.sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }.first?.key ?? filter
            filterSamples += 1
        }
        count += 1
    }
}

final class DirectorPreferenceStore {
    static let shared = DirectorPreferenceStore()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey = "director.preferences.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func read() -> [String: DirectorPreference] {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode([String: DirectorPreference].self, from: data) else { return [:] }
        return value
    }
    func preference(for context: DirectorLearningContext) -> DirectorPreference? {
        lock.lock(); defer { lock.unlock() }
        return read()[context.key]
    }
    var feedbackCount: Int {
        lock.lock(); defer { lock.unlock() }
        return read().values.reduce(0) { $0 + $1.count }
    }
    func learn(context: DirectorLearningContext, filter: String, strength: Double, framingFeedback: String) {
        lock.lock(); defer { lock.unlock() }
        var profiles = read()
        var value = profiles[context.key] ?? DirectorPreference()
        value.learn(context: context, filter: filter, strength: strength, framingFeedback: framingFeedback)
        profiles[context.key] = value
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: storageKey) }
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }
}

struct DirectorInput {
    var observation: DirectorObservation
    var scene: String
    var sceneConfidence: Double
    var zoom: Double
    var minimumZoom: Double
    var maximumZoom: Double
    var nativeMaximumZoom: Double
    var stable: Bool
    var framing: String // 自动 / 环境 / 全身 / 半身 / 肖像
    var composition: String // 自动 / 居中 / 三分
    var preference: DirectorPreference?
}

struct DirectorDecision: Equatable {
    var targetZoom = 1.0
    var shouldZoom = false
    var filter = "自然"
    var maximumFilterStrength = 0.55
    var exposureBias = 0.0
    var protectHighlights = false
    var liftShadows = false
    var ready = false
    var context: DirectorLearningContext?
    var evidence: [DirectorEvidence] = []
    var summary: String { evidence.last?.action ?? "等待可靠画面" }
}

// Adapted from wearereasonablepeople/KalmanFilter, KalmanFilter/KalmanFilter.swift.
// Copyright (c) 2019 WEAREREASONABLEPEOPLE B.V.; source header (c) 2016 Oleksii Dykan.
// Scalar specialization (F=H=1, B=0); upstream MIT license in DirectorLicenses.
struct DirectorKalman {
    var estimate: Double
    var covariance = 1.0
    mutating func update(_ measurement: Double) -> Double {
        let predictedStateEstimate = estimate
        let predictedEstimateCovariance = covariance + 0.0002
        let measurementResidual = measurement - predictedStateEstimate
        let residualCovariance = predictedEstimateCovariance + 0.002
        let kalmanGain = predictedEstimateCovariance / residualCovariance
        estimate = predictedStateEstimate + kalmanGain * measurementResidual
        covariance = (1 - kalmanGain) * predictedEstimateCovariance
        return estimate
    }
}

// Adapted from jwagner/smartcrop.js importance()/thirds(), MIT (c) 2016 Jonas Wagner.
// This is the crop-position scoring portion, not the full smartcrop pixel detector.
enum DirectorCropImportance {
    static func thirds(_ input: Double) -> Double {
        let x = (((input - 1 / 3 + 1).truncatingRemainder(dividingBy: 2)) * 0.5 - 0.5) * 16
        return max(1 - x * x, 0)
    }
    static func score(x: Double, y: Double, ruleOfThirds: Bool) -> Double {
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return -0.5 }
        let px = abs(0.5 - x) * 2
        let py = abs(0.5 - y) * 2
        let dx = max(px - 0.6, 0)
        let dy = max(py - 0.6, 0)
        let d = (dx * dx + dy * dy) * -20
        var s = 1.41 - sqrt(px * px + py * py)
        if ruleOfThirds { s += max(0, s + d + 0.5) * 1.2 * (thirds(px) + thirds(py)) }
        return s + d
    }
}

enum DirectorEngine {
    static func context(_ input: DirectorInput) -> DirectorLearningContext {
        DirectorLearningContext(scene: input.scene, kind: input.observation.subjectKind,
                                group: input.observation.personCount > 1,
                                subjectFraction: input.observation.subject?.height ?? 0,
                                automaticFraming: input.framing == "自动")
    }

    static func evaluate(_ input: DirectorInput) -> DirectorDecision {
        let o = input.observation
        let requestedZoom = input.zoom.isFinite && input.zoom > 0 ? input.zoom : 1
        let lower = max(0.01, input.minimumZoom.isFinite ? input.minimumZoom : 1)
        let upper = max(lower, input.maximumZoom.isFinite ? input.maximumZoom : lower)
        let zoom = max(lower, min(requestedZoom, upper))
        var decision = DirectorDecision(targetZoom: zoom)
        decision.context = context(input)
        func evidence(_ domain: String, _ rule: String, _ observation: String, _ action: String) -> DirectorEvidence {
            DirectorEvidence(domain: domain, rule: rule, observation: observation, action: action)
        }
        // Light/color decisions use measured image statistics, not a guessed light-source direction.
        decision.protectHighlights = o.highlights > 0.045
        decision.liftShadows = o.shadows > 0.32 && o.highlights < 0.03
        decision.exposureBias = decision.protectHighlights ? -0.3 : decision.liftShadows ? 0.2 : 0
        if o.subjectBrightness < 0.25 && o.brightness > o.subjectBrightness + 0.18 {
            decision.evidence.append(evidence("光线色彩", "逆光与动态范围", "主体比整体画面暗", "保护亮部，优先换角度或补光，不强行提亮阴影"))
        } else if decision.protectHighlights {
            decision.evidence.append(evidence("光线色彩", "高光保护", "亮部接近饱和的采样增加", "小幅压曝光；已溢出的细节不能凭空恢复"))
        } else {
            decision.evidence.append(evidence("光线色彩", "明暗关系", "亮暗分布处于可用范围", "保留现场明暗，不强制HDR拉平"))
        }
        if abs(o.leftBrightness - o.rightBrightness) > 0.18 {
            decision.evidence.append(evidence("光线色彩", "画面亮度平衡", o.leftBrightness > o.rightBrightness ? "画面左侧更亮" : "画面右侧更亮", "检查亮部是否抢主体；这不等同于判断真实光源方向"))
        }
        // Filter selection is conservative for skin and low-confidence recognition.
        let person = o.personCount > 0
        if person { decision.filter = "人像" }
        else if input.sceneConfidence < 0.65 { decision.filter = "自然" }
        else {
            switch input.scene {
            case "日落": decision.filter = "日落"
            case "夜景": decision.filter = "夜景"
            case "花草": decision.filter = "森系"
            case "风景", "海边": decision.filter = "风景"
            default: decision.filter = "自然"
            }
        }
        if o.saturation > 0.48 || (person && o.warmth > 0.14) { decision.filter = "自然" }
        if let preference = input.preference, preference.filterSamples >= 3 {
            // Apply the user's context-specific choices, bounded by present image quality.
            decision.filter = preference.preferredFilter
            decision.maximumFilterStrength = max(0.15, min(0.8, preference.filterStrength))
        }
        if person { decision.maximumFilterStrength = min(0.5, decision.maximumFilterStrength) }
        if o.saturation > 0.48 || decision.protectHighlights { decision.maximumFilterStrength = min(0.4, decision.maximumFilterStrength) }
        decision.evidence.append(evidence("滤镜", "自然色与肤色优先", "滤镜：" + decision.filter, "按场景和用户反馈选风格，对高饱和与人像限制强度"))
        guard let box = o.subject, box.valid, o.confidence >= 0.65 else {
            decision.evidence.append(evidence("人物定位", "可靠主体门控", "未检测到可靠主体", "保持当前倍率，不根据猜测自动追焦放大"))
            return decision
        }
        var desired: Double
        if o.subjectKind == "face" {
            desired = input.framing == "突出主体" ? 0.30 : 0.20
        } else {
            switch input.framing {
            case "环境": desired = 0.42
            case "完整人物": desired = 0.70
            case "突出主体": desired = 0.80
            default: desired = o.personCount > 1 ? 0.62 : person ? 0.58 : 0.42
            }
        }
        if !person && ["风景", "海边", "日落", "夜景"].contains(input.scene) { desired = min(desired, 0.32) }
        if input.framing == "自动", let p = input.preference, p.occupancySamples >= 3 {
            desired = max(0.08, min(0.82, p.subjectFraction))
        }
        decision.evidence.append(evidence("人物定位", o.personCount > 1 ? "合影完整性" : o.subjectKind == "face" ? "人脸与全身区分" : "主体占比", "目标占高约" + String(Int(desired * 100)) + "%", o.subjectKind == "face" ? "只有人脸证据，不能据此保证全身入镜" : "优先保留完整人物与头顶留白，不机械放大人脸"))
        let clipped = box.x < 0.025 || box.maxX > 0.975 || box.y < 0.025 || box.maxY > 0.975
        let needsChange = clipped || abs(log(max(0.01, box.height) / desired)) > 0.17
        let thirds = input.composition == "三分" || (input.composition == "自动" && !person)
        func score(_ target: Double) -> Double {
            let ratio = target / zoom
            let predicted = box.scaledAroundCenter(ratio)
            if ratio > 1.001 && (predicted.x < 0.05 || predicted.maxX > 0.95 || predicted.y < 0.05 || predicted.maxY > 0.94) { return -100 }
            let occupancy = -abs(log(max(0.01, predicted.height) / desired))
            let margin = min(predicted.x, min(predicted.y, min(1 - predicted.maxX, 1 - predicted.maxY)))
            let edgePenalty = min(0, margin - 0.045) * 12
            let position = DirectorCropImportance.score(x: predicted.midX, y: predicted.midY, ruleOfThirds: thirds) * 0.10
            let digital = max(0, log(target / max(1, input.nativeMaximumZoom)))
            let qualityPenalty = digital * (o.brightness < 0.22 || o.sharpness < 65 || input.scene == "夜景" ? 0.6 : 0.08)
            let movementPenalty = abs(log(ratio)) * 0.08
            return occupancy + edgePenalty + position - qualityPenalty - movementPenalty
        }
        var best = zoom
        var bestScore = score(zoom)
        for factor in [0.85, 0.92, 1.08, 1.15] {
            let candidate = max(lower, min(upper, zoom * factor))
            if o.brightness < 0.20 && candidate > zoom { continue }
            if o.sharpness < 55 && candidate > zoom { continue }
            if o.subjectBrightness > 0.9 && input.scene == "日落" && candidate > zoom { continue }
            if score(candidate) > bestScore + 0.025 { best = candidate; bestScore = score(candidate) }
        }
        let canZoom = input.stable && abs(o.horizon) < 0.14 && needsChange
        decision.targetZoom = canZoom ? best : max(lower, min(upper, zoom))
        decision.shouldZoom = canZoom && abs(log(decision.targetZoom / zoom)) > 0.045
        let action = decision.shouldZoom ? (best > zoom ? "小幅推近，达到主体占比" : "小幅拉远，保留人物和留白") : "保持当前倍率"
        decision.evidence.append(evidence("构图", thirds ? "三分与边缘重要性" : "居中与视觉平衡", clipped ? "主体靠近画面边界" : "比较中心裁切候选方案", action))
        if abs(o.horizon) > 0.06 {
            decision.evidence.append(evidence("拍摄技巧", "水平与透视", "水平线存在倾斜", "先校平手机；变焦不能代替移动机位或改变透视"))
        }
        if !input.stable || o.brightness < 0.20 || o.sharpness < 55 {
            decision.evidence.append(evidence("拍摄技巧", "稳定、快门与细节", "暗光、细节不足或机身不稳定", "暂停推近，先稳住手机、补光或重新对焦"))
        }
        decision.ready = input.stable && !clipped && !decision.shouldZoom && abs(o.horizon) < 0.06 && o.sharpness >= 65 && o.brightness > 0.16 && o.brightness < 0.88
        return decision
    }
}

/// Temporal controller: smooth normalized/world occupancy, verify continuity, then dwell.
/// Smoothing measured height directly would lag behind our own zoom and cause hunting.
struct DirectorController {
    private var smoother: DirectorKalman?
    private var lastBox: DirectorBox?
    private var lastSignature = ""
    private var lastObservationTime = -Double.infinity
    private var lastZoomTime = -Double.infinity
    private var direction = 0
    private var streak = 0

    mutating func reset() { self = DirectorController() }
    mutating func evaluate(_ input: DirectorInput, now: Double, allowAutomaticZoom: Bool) -> DirectorDecision {
        var filtered = input
        guard let box = input.observation.subject, box.valid, input.observation.confidence >= 0.65 else {
            smoother = nil; lastBox = nil; streak = 0
            return DirectorEngine.evaluate(input)
        }
        let signature = input.scene + input.observation.subjectKind + String(input.observation.personCount)
        let discontinuity = signature != lastSignature || now - lastObservationTime > 0.8 || (lastBox.map { $0.overlap(box) < 0.25 } ?? true)
        let normalizedHeight = box.height / max(0.01, input.zoom)
        if discontinuity { smoother = DirectorKalman(estimate: normalizedHeight); streak = 0 }
        let smoothed = smoother?.update(normalizedHeight) ?? normalizedHeight
        var adjusted = box
        adjusted.height = max(0.01, min(1.5, smoothed * input.zoom))
        adjusted.y = box.midY - adjusted.height / 2
        filtered.observation.subject = adjusted
        lastSignature = signature; lastObservationTime = now; lastBox = box
        var decision = DirectorEngine.evaluate(filtered)
        // Keep the raw measured context for user feedback, never the smoothed estimate.
        decision.context = DirectorEngine.context(input)
        // The raw box always vetoes a crop, even if the smoother lags a fast approach.
        let rawPrediction = box.scaledAroundCenter(decision.targetZoom / max(0.01, input.zoom))
        if decision.targetZoom > input.zoom &&
            (rawPrediction.x < 0.05 || rawPrediction.maxX > 0.95 || rawPrediction.y < 0.05 || rawPrediction.maxY > 0.94) {
            decision.shouldZoom = false
            decision.targetZoom = input.zoom
        }
        let nextDirection = decision.targetZoom > input.zoom ? 1 : -1
        if !allowAutomaticZoom || !decision.shouldZoom {
            if decision.shouldZoom && !allowAutomaticZoom {
                decision.evidence.append(DirectorEvidence(domain: "拍摄技巧", rule: "自动控制门控", observation: "开关、手动接管或拍摄状态暂不允许变焦", action: "本轮保留建议，不执行自动变焦"))
            }
            streak = 0; decision.shouldZoom = false; return decision
        }
        streak = nextDirection == direction ? streak + 1 : 1
        direction = nextDirection
        if streak < 4 || now - lastZoomTime < 1.4 {
            decision.shouldZoom = false
            decision.evidence.append(DirectorEvidence(domain: "拍摄技巧", rule: "连续确认与冷却", observation: "候选取景正在确认或镜头尚在稳定", action: "等待后续画面，不立即重复变焦"))
            return decision
        }
        lastZoomTime = now; streak = 0
        return decision
    }
}


enum DirectorKnowledge {
    static let domains: [(name: String, principles: String)] = [
        ("构图", "三分与居中并存；比较候选取景；检查边缘、留白与主体占比。"),
        ("光线色彩", "采样亮暗分布、主体与背景反差、饱和度和偏色线索；保护亮部、保留阴影；不把画面亮侧冒充光源方向。"),
        ("滤镜", "按场景选择风格；优先自然肤色；高饱和与人像降低强度；有足够反馈后使用同场景偏好。"),
        ("人物定位", "区分人脸、人体和多人；联合人物框；推近前保护完整人物和头顶空间。"),
        ("摄影技巧", "低光和手抖时停止推近；限制数字放大代价；主体丢失、切镜头或手动接管时暂停并重新确认。")
    ]
}

enum DirectorLicenses {
    static let smartcrop = """
Copyright (c) 2016 Jonas Wagner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
    static let kalman = """
MIT License

Copyright (c) 2019 WEAREREASONABLEPEOPLE B.V.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""
}
