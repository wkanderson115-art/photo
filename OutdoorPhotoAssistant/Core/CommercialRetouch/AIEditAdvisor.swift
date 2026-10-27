import Foundation
import UIKit

// MARK: - 建议模型
//
// 这里是单张精修页与批量精修台共用的「AI 修图建议」模型与规则引擎。
// 规则来自 `CommercialRetouchView` 里原本内联实现的那一套，逐条搬过来，阈值、
// 文案与失败计数口径完全一致，只是补了一个 `failureCount` 供批处理汇总使用。
// 本文件刻意只依赖 Foundation：不 import SwiftUI / UIKit，方便在 runner 里直接调用。

/// 一条可执行的 AI 修图建议：指标 → 现象 → 建议动作 → 建议参数。
struct AIEditSuggestion: Identifiable, Equatable {
    let id = UUID()
    let metric: String        // 指标名，如「肤色 ΔE」
    let finding: String       // 现象，如「肤色 ΔE00 4.09，超过 3.00 上限」
    let action: String        // 建议动作，如「AI 阶段只做肤色自然化，禁止整体换色」
    let parameter: String     // 建议参数，如「肤色 ΔE 目标 ≤2.0；强度 ≤0.9；预设 商业自然」
}

/// 本地精修完成后产出的整套 AI 修图建议，含可直接发送给 Seedream 的提示词。
struct AIEditAdvice: Equatable {
    var items: [AIEditSuggestion]
    var prompt: String              // 可直接发送给 Seedream 的完整中文提示词
    var recommendedPresetID: String
    var recommendedStrength: Double
    var headline: String            // 一句话结论
    var failureCount: Int           // 未合规项数（决定建议强度与批次汇总口径）
}

// MARK: - 规则引擎

enum AIEditAdvisor {

    /// 把一次质检报告翻译成可执行的 AI 修图建议。
    ///
    /// 11 条规则与 `CommercialRetouchView` 里的实现逐条对应：前 7 条按 `report.metrics`
    /// 的键判定（阈值：肤色 ΔE 3.0 / 1.5、裁切 0.0100 与 0.0020、纹理 0.50、接缝 0.30、
    /// SSIM 0.85），第 8 条看剩余瑕疵，第 9 条在质检通过时给 3 条增殖建议，第 10 条是
    /// 「未通过：」note 的兜底，第 11 条是全部不命中时的通用建议。
    /// 每个判定都带具体数值，不写空话。
    static func makeAdvice(report: RetouchQualityReport, look: RetouchLook, presetID: String,
                           strength: Double, spotsFound: Int, spotsRemaining: Int) -> AIEditAdvice {
        var items: [AIEditSuggestion] = []
        var failures = 0
        let metrics = report.metrics
        let notes = report.notes

        func add(metric: String, finding: String, action: String, parameter: String, failure: Bool) {
            if failure { failures += 1 }
            items.append(AIEditSuggestion(metric: metric, finding: finding,
                                          action: action, parameter: parameter))
        }

        // ① 肤色色差
        if let tone = metrics["skin_tone_de"] {
            if tone > 3.0 {
                add(metric: "肤色 ΔE",
                    finding: String(format: "肤色 ΔE00 %.2f，超过 3.00 上限", tone),
                    action: "AI 阶段只做肤色自然化、把色差拉回 ≤2.00，禁止整体换色或加暖色滤镜",
                    parameter: String(format: "肤色 ΔE 目标 ≤2.00（当前 %.2f）；强度 ≤0.85；预设选 商业自然", tone),
                    failure: true)
            } else if tone >= 1.5 {
                add(metric: "肤色 ΔE",
                    finding: String(format: "肤色微偏：ΔE00 %.2f，处在 1.50–3.00 临界区", tone),
                    action: "肤色微偏，AI 不要叠加任何暖色/橙色调，只做中性回正",
                    parameter: String(format: "肤色 ΔE 目标 ≤1.50（当前 %.2f）；强度 ≤0.90", tone),
                    failure: false)
            }
        } else if let note = noteFallback(notes, keyword: "ΔE00") {
            add(metric: "肤色 ΔE", finding: note,
                action: "AI 阶段只做肤色自然化、把色差拉回 ≤2.00，禁止整体换色或加暖色滤镜",
                parameter: "肤色 ΔE 目标 ≤2.00；强度 ≤0.85；预设选 商业自然",
                failure: true)
        }

        // ② 全图高光/死黑裁切
        if let clip = metrics["clipping_full"] {
            if clip > 0.0100 {
                add(metric: "整体裁切",
                    finding: String(format: "全图高光/死黑裁切 %.4f，超过 0.0100 上限", clip),
                    action: "高光/死黑溢出，AI 必须恢复高光与暗部层次，输出禁止出现纯白/纯黑",
                    parameter: String(format: "要求 AI 保留 1%%–99%% 动态范围（当前裁切 %.4f）；强度 ≤0.90", clip),
                    failure: true)
            }
        } else if let note = noteFallback(notes, keyword: "全图高光") {
            add(metric: "整体裁切", finding: note,
                action: "高光/死黑溢出，AI 必须恢复高光与暗部层次，输出禁止出现纯白/纯黑",
                parameter: "要求 AI 保留 1%–99% 动态范围；强度 ≤0.90",
                failure: true)
        }

        // ③ 皮肤高光裁切
        if let clip = metrics["clipping_skin"] {
            if clip > 0.002 {
                add(metric: "肤色裁切",
                    finding: String(format: "皮肤高光/死黑裁切 %.4f，超过 0.0020 上限", clip),
                    action: "皮肤高光溢出，AI 压低皮肤高光、保留过渡，不许把皮肤压成灰面",
                    parameter: String(format: "皮肤高光裁切目标 ≤0.0015（当前 %.4f）；强度 ≤0.85", clip),
                    failure: true)
            }
        } else if let note = noteFallback(notes, keyword: "皮肤高光") {
            add(metric: "肤色裁切", finding: note,
                action: "皮肤高光溢出，AI 压低皮肤高光、保留过渡",
                parameter: "皮肤高光裁切目标 ≤0.0015；强度 ≤0.85",
                failure: true)
        }

        // ④ 磨皮过度
        if let texture = metrics["texture_retention"] {
            if texture < 0.50 {
                add(metric: "纹理保留",
                    finding: String(format: "纹理保留率 %.2f，低于 0.50 下限（磨皮过度）", texture),
                    action: "磨皮过度，AI 回补皮肤纹理与毛孔，禁止再磨皮",
                    parameter: String(format: "纹理保留目标 ≥0.55（当前 %.2f）；AI 阶段磨皮强度 0；强度 ≤0.80", texture),
                    failure: true)
            }
        } else if let note = noteFallback(notes, keyword: "皮肤纹理保留率") {
            add(metric: "纹理保留", finding: note,
                action: "磨皮过度，AI 回补皮肤纹理与毛孔，禁止再磨皮",
                parameter: "纹理保留目标 ≥0.55；AI 阶段磨皮强度 0；强度 ≤0.80",
                failure: true)
        }

        // ⑤ 蒙版接缝
        if let seam = metrics["seam_ratio"] {
            if abs(seam - 1.0) > 0.30 {
                add(metric: "接缝比例",
                    finding: String(format: "蒙版接缝梯度比 %.2f，偏离 1.00 达 %.2f（阈 0.30）", seam, abs(seam - 1.0)),
                    action: "接缝明显，AI 只做整体色调过渡，禁止局部重绘五官",
                    parameter: String(format: "接缝比目标 0.85–1.15（当前 %.2f）；禁止局部重绘；强度 ≤0.85", seam),
                    failure: true)
            }
        } else if let note = noteFallback(notes, keyword: "接缝") {
            add(metric: "接缝比例", finding: note,
                action: "接缝明显，AI 只做整体色调过渡，禁止局部重绘五官",
                parameter: "接缝比目标 0.85–1.15；禁止局部重绘；强度 ≤0.85",
                failure: true)
        }

        // ⑥ 结构相似度
        if let ssim = metrics["ssim"] {
            if ssim < 0.85 {
                add(metric: "SSIM",
                    finding: String(format: "结构相似度 %.3f，低于 0.85 下限（改动过大）", ssim),
                    action: "改动过大，AI 限制改动范围到肤色与光影，不许改脸型、五官、构图",
                    parameter: String(format: "SSIM 目标 ≥0.90（当前 %.3f）；强度 ≤0.80", ssim),
                    failure: true)
            }
        } else if let note = noteFallback(notes, keyword: "结构相似度") {
            add(metric: "SSIM", finding: note,
                action: "改动过大，AI 限制改动范围到肤色与光影，不许改脸型、五官、构图",
                parameter: "SSIM 目标 ≥0.90；强度 ≤0.80",
                failure: true)
        }

        // ⑦ 剩余瑕疵
        if spotsRemaining > 0 {
            add(metric: "剩余瑕疵",
                finding: "仍有 \(spotsRemaining) 处瑕疵未清理（本次检测 \(spotsFound) 处）",
                action: "AI 清理时避开眼周、唇线、发丝，只做小范围点修",
                parameter: "点修半径 ≤ 画面长边 0.5%；强度 ≤0.80",
                failure: !report.passed)
        }

        // ⑧ 已通过时的增殖建议（至少 3 条）
        if report.passed {
            add(metric: "补光层次",
                finding: "本地质检已通过，光比与层次仍有加强空间",
                action: "AI 只做轻微补光与层次分离，主光方向不变",
                parameter: "强度 ≤0.90；禁止改变光源方向与投影",
                failure: false)
            add(metric: "背景干净度",
                finding: "背景允许小幅清理，但结构必须保留",
                action: "AI 只清理背景杂物与噪点，禁止替换天空、禁止生成新物体",
                parameter: "背景改动幅度 ≤5%；结构保持不变",
                failure: false)
            add(metric: "锐化控制",
                finding: "本地已做过锐化，二次锐化会产生白边",
                action: "AI 阶段禁止再加锐化/清晰度，输出保持柔和过渡",
                parameter: "锐化增量 0；禁止 HDR 与高反差",
                failure: false)
        }

        // ⑧.5 兜底：任何没被上面规则命中的「未通过：」note 也翻译成建议
        let usedFindings = Set(items.map { $0.finding })
        for note in notes where note.hasPrefix("未通过：") && !usedFindings.contains(note) {
            add(metric: "质检未通过项", finding: note,
                action: "按该条不通过项限制 AI 改动范围，只修对应缺陷，其余保持不动",
                parameter: "对应指标拉回阈值内；强度 ≤0.85",
                failure: true)
        }

        // ⑨ 无任何命中
        if items.isEmpty {
            let tone = metrics["skin_tone_de"] ?? 0
            let retention = metrics["texture_retention"] ?? 0
            let ssim = metrics["ssim"] ?? 0
            add(metric: "综合",
                finding: String(format: "本地质检通过：肤色 ΔE %.2f、纹理保留 %.2f、SSIM %.3f 均在阈值内",
                                tone, retention, ssim),
                action: "无需纠正，AI 只做氛围微调",
                parameter: "强度 ≤0.80",
                failure: false)
        }

        // 建议强度：未合规项越多越低，每项 -0.05，下限 0.70
        let rawStrength = report.passed ? strength : max(0.70, strength - 0.05 * Double(failures))
        let recommendedStrength = min(1.30, (rawStrength * 20).rounded() / 20)

        // 建议预设：肤色类失败优先换到「商业自然」（aiAllowed）预设
        var recommendedPresetID = presetID
        let toneFailed: Bool
        if let tone = metrics["skin_tone_de"] {
            toneFailed = tone > 3.0
        } else {
            toneFailed = noteFallback(notes, keyword: "ΔE00") != nil
        }
        if toneFailed, let commercial = RetouchPresetCatalog.all.first(where: { $0.look == .commercialNatural && $0.aiAllowed }) {
            recommendedPresetID = commercial.id
        }

        let presetName = RetouchPresetCatalog.find(recommendedPresetID).name
        let actions = items.map { $0.action }
        let corrections = actions.isEmpty ? "无需纠正，只做氛围微调" : actions.joined(separator: "；")
        let strengthText = String(format: "%.2f", recommendedStrength)
        let prompt = "专业商业后期。第 1 步保持人物身份、五官、脸型、构图、尺寸完全不变；"
            + "第 2 步按以下纠正：" + corrections + "；"
            + "第 3 步保留真实皮肤纹理与毛孔，禁止磨皮成塑料感、禁止改变天空/背景结构、禁止生成新物体；"
            + "风格：" + presetName + "，强度 " + strengthText + "。"

        let headline = report.passed
            ? "本地已合规，AI 只做加强"
            : "本地未合规 \(failures) 项，以下是 AI 阶段的纠正清单"

        _ = look
        return AIEditAdvice(items: items, prompt: prompt,
                            recommendedPresetID: recommendedPresetID,
                            recommendedStrength: recommendedStrength,
                            headline: headline,
                            failureCount: failures)
    }

    /// 从质检 notes 里捞兜底 finding：只认「未通过：」开头且含关键字的句子。
    static func noteFallback(_ notes: [String], keyword: String) -> String? {
        notes.first { $0.hasPrefix("未通过：") && $0.contains(keyword) }
    }

    // MARK: - 摘要

    /// 单张一句话摘要：
    /// 例 `未合规 2 项 · 建议强度 0.85 · 肤色 ΔE / 整体裁切`；
    /// 全部合规时是 `全部合规 · 建议强度 1.00 · 补光层次 / 背景干净度 / 锐化控制`。
    static func brief(_ advice: AIEditAdvice) -> String {
        let head = advice.failureCount > 0 ? "未合规 \(advice.failureCount) 项" : "全部合规"
        var seen = Set<String>()
        var metrics: [String] = []
        for item in advice.items where !seen.contains(item.metric) {
            seen.insert(item.metric)
            metrics.append(item.metric)
        }
        let metricText = metrics.isEmpty ? "无" : metrics.joined(separator: " / ")
        return head + " · 建议强度 " + String(format: "%.2f", advice.recommendedStrength)
            + " · " + metricText
    }

    /// 整批汇总：
    /// 例 `12 张中 5 张本地未合规（肤色 ΔE 3 张、整体裁切 2 张）；建议统一用「商业自然」+ 强度 0.85 跑一轮 AI`；
    /// 全合规时 `12 张本地全部合规，可按当前设置直接交付`。
    /// 指标清单按「出现在几张未合规照片上」从多到少取前 3 条。
    static func batchSummary(_ advices: [AIEditAdvice], photoCount: Int) -> String {
        let total = max(photoCount, advices.count)
        guard !advices.isEmpty else {
            return "还没有本地精修结果：先跑完本地精修，再为已处理照片生成 AI 修图建议"
        }
        let failing = advices.filter { $0.failureCount > 0 }
        if failing.isEmpty {
            return "\(total) 张本地全部合规，可按当前设置直接交付"
        }

        var metricCounts: [String: Int] = [:]
        for advice in failing {
            for metric in Set(advice.items.map { $0.metric }) {
                metricCounts[metric, default: 0] += 1
            }
        }
        let topMetrics = metricCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key) \($0.value) 张" }
            .joined(separator: "、")
        let metricText = topMetrics.isEmpty ? "未命中具体指标" : topMetrics

        let presetID = mostCommon(failing.map { $0.recommendedPresetID }) ?? failing[0].recommendedPresetID
        let presetName = RetouchPresetCatalog.find(presetID).name
        let strength = failing.map { $0.recommendedStrength }.min() ?? 0.85
        let strengthText = String(format: "%.2f", strength)
        return "\(total) 张中 \(failing.count) 张本地未合规（\(metricText)）；建议统一用「\(presetName)」+ 强度 \(strengthText) 跑一轮 AI"
    }

    /// 出现次数最多的值；并列时取先出现的那个，保证同一批次结果稳定。
    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for value in values {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        var best: String?
        var bestCount = 0
        for value in order {
            let count = counts[value] ?? 0
            if count > bestCount {
                best = value
                bestCount = count
            }
        }
        return best
    }
}
