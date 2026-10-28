import SwiftUI
import PhotosUI
import UIKit
import Foundation

struct CommercialRetouchView: View {
    private enum PreviewMode: String, CaseIterable, Identifiable {
        case original = "原图"
        case retouched = "精修"
        case compare = "对比"
        var id: String { rawValue }
    }

    @State private var picker: PhotosPickerItem?
    @State private var originalData: Data?
    @State private var original: UIImage?
    @State private var localResult: UIImage?
    @State private var aiResult: UIImage?
    @State private var fusedResult: UIImage?
    @State private var allowPaidCall = false
    @State private var aiCalls = 0
    @State private var presetID = "p25"
    @State private var engine: RetouchEngineChoice = .dual
    @State private var suggestion = "选择照片后，使用 Vision 推荐预设；可随时更改。"
    @State private var status = ""
    @State private var jobID: UUID?
    @State private var exportURL: URL?
    @State private var versionURLs: [URL] = []
    @State private var selectedRevision: URL?
    @State private var busy = false
    @State private var spotMode = false
    @State private var recoverableJobs: [UUID] = []

    // MARK: new state (strength / comparison / QC / blemish count)
    @State private var strength: Double = 1.0
    @State private var previewMode: PreviewMode = .retouched
    @State private var qualityReport: RetouchQualityReport?
    @State private var spotsFound = 0
    @State private var spotsRemaining = 0
    @State private var lastLook: RetouchLook?

    private let pipeline = RetouchPipeline()
    private let store = RetouchVersionStore()

    /// Stable display order for the metrics the pipeline emits; any additional
    /// key the pipeline adds later is appended in sorted order instead of hidden.
    private static let metricOrder = [
        "texture_retention",
        "skin_tone_de",
        "skin_luma_shift",
        "clipping_skin",
        "clipping_full",
        "seam_ratio",
        "ssim",
        "blemish_clearance",
        "spots_before"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("单张精修").font(.title2.bold()).foregroundStyle(AppTheme.ink)
                    Text("先选照片，再确认场景预设和处理方式；原图始终保留。")
                        .font(.subheadline).foregroundStyle(AppTheme.muted)
                    PhotosPicker(selection: $picker, matching: .images) {
                        Label("选择照片并智能识别", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity).padding(14)
                    }.buttonStyle(.borderedProminent)

                    if let original {
                        Picker("预览视图", selection: $previewMode) {
                            ForEach(PreviewMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }.pickerStyle(.segmented)
                        previewArea(original: original)
                        Text(previewHint).font(.caption).foregroundStyle(.secondary)
                        if let qualityReport {
                            qcPanel(qualityReport)
                        }
                    }

                    Text(suggestion).font(.caption).foregroundStyle(.secondary)

                    Picker("摄影预设", selection: $presetID) {
                        ForEach(RetouchPresetCatalog.categories, id: \.self) { category in
                            Section(category) {
                                ForEach(RetouchPresetCatalog.presets(for: category)) { preset in
                                    Text(preset.name).tag(preset.id)
                                }
                            }
                        }
                    }.pickerStyle(.menu)
                    Text("当前预设：\(RetouchPresetCatalog.find(presetID).name) · \(RetouchPresetCatalog.find(presetID).look.displayName)")
                        .font(.caption).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("精修强度").font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2f", strength))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $strength, in: 0.4...1.3, step: 0.05)
                            .accessibilityLabel("精修强度")
                            .disabled(busy)
                        Text("0.40–1.30，默认 1.00。强度越高磨皮与光影差异越明显；商业交付建议 0.90–1.10，改动强度后需重新执行本地精修。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Picker("精修引擎", selection: $engine) {
                        ForEach(RetouchEngineChoice.allCases) { mode in
                            Text(mode == .local ? "本地" : mode == .seedream ? "AI" : "双引擎").tag(mode)
                        }
                    }.pickerStyle(.segmented)
                    Text("当前模式：\(engine.rawValue)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.ink)
                    Text(engine == .dual ? "双引擎安全模式：先保存本地版；AI 不会自动覆盖或伪装为已融合。" : engine == .seedream ? "Seedream 使用现有图库中的独立云端修图入口。" : "仅在本机执行，无 API 费用。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("执行本地精修并独立保存") { runLocal() }
                        .buttonStyle(.borderedProminent).disabled(original == nil || busy || engine == .seedream)

                    if engine != .local {
                        Toggle("允许本次付费 Seedream 调用（最多 1 次）", isOn: $allowPaidCall)
                        Button(engine == .dual ? "执行双引擎（先本地、再按需 AI）" : "执行独立 Seedream 精修") {
                            Task { await runAI(dual: engine == .dual) }
                        }.buttonStyle(.borderedProminent).disabled(original == nil || busy || !allowPaidCall || aiCalls >= 1)
                        NavigationLink("打开图库 · Seedream 独立入口") { GalleryView() }
                            .buttonStyle(.bordered)
                        Text("AI 调用会产生服务商费用。融合仅在极少量像素变化且同尺寸时尝试；否则 AI 版单独保存并提示人工复核。")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    if localResult != nil {
                        Text("本地版本已生成。可继续检查，原始照片未覆盖。")
                            .font(.subheadline)
                        Toggle("瑕疵检测（点选局部修复）", isOn: $spotMode)
                        Text("开启后在「精修」视图里点按小瑕疵；每次修复独立保存，可在历史版本中回退。请避开眼、嘴、发丝与清晰边缘。上次检测到 \(spotsFound) 处，剩余 \(spotsRemaining) 处待处理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if !versionURLs.isEmpty {
                        Text("所有版本历史（原图 / 本地 / AI / 融合互不覆盖）").font(.headline)
                        ForEach(versionURLs, id: \.self) { url in
                            HStack {
                                Button {
                                    selectedRevision = url
                                    exportURL = url
                                    status = "已切换预览至历史版本；没有修改或覆盖任何文件。"
                                } label: {
                                    Label(url.lastPathComponent, systemImage: selectedRevision == url ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                                }.buttonStyle(.plain)
                                Spacer()
                                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            }
                        }
                    }
                    if !recoverableJobs.isEmpty {
                        Menu("恢复之前的精修任务") {
                            ForEach(recoverableJobs, id: \.self) { id in
                                Button(id.uuidString.prefix(8).description) { restore(id) }
                            }
                        }
                    }
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("分享 / 导出本地 JPEG", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    }
                    if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    Text("质量门禁：JPEG 技术验证与保守融合拒绝已接入。人物身份、毛孔真实性、AI 伪影和商业授权仍必须人工审核。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }.navigationTitle("智能精修").navigationBarTitleDisplayMode(.inline)
                .onAppear { recoverableJobs = RetouchRecovery().jobs() }
                .onChange(of: picker) { newValue in
                    Task {
                        guard let data = try? await newValue?.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { status = "照片读取失败"; return }
                        originalData = data
                        original = image
                        localResult = nil; aiResult = nil; fusedResult = nil
                        exportURL = nil; versionURLs = []; selectedRevision = nil
                        aiCalls = 0; allowPaidCall = false; spotMode = false
                        qualityReport = nil; spotsFound = 0; spotsRemaining = 0
                        lastLook = nil; previewMode = .retouched
                        do { jobID = try store.newJob(originalData: data) }
                        catch { status = "原图存档失败：\(error.localizedDescription)"; return }
                        let (recommended, message) = await pipeline.suggestPreset(image: image)
                        presetID = recommended.id
                        suggestion = "推荐：\(recommended.name)。\(message)"
                    }
                }
        }
    }

    // MARK: - Preview

    /// The image that currently represents "the retouched result".
    private var displayedResult: UIImage? {
        if let selectedRevision, let image = UIImage(contentsOfFile: selectedRevision.path) {
            return image
        }
        return fusedResult ?? aiResult ?? localResult
    }

    private var previewHint: String {
        switch previewMode {
        case .original:
            return "当前为原图，未经任何处理；原图字节始终保留在任务目录中。"
        case .retouched:
            if displayedResult == nil { return "尚未生成精修版本，此处暂显示原图。" }
            return spotMode ? "点按画面中的小瑕疵即可局部修复，每次修复独立保存为新版本。" : "当前为最近一次精修结果；可切换「对比」逐块查看差异。"
        case .compare:
            return "左为原图、右为精修结果，同一圆角裁切内并排显示；点选修复请在「精修」视图中操作。"
        }
    }

    @ViewBuilder
    private func previewArea(original: UIImage) -> some View {
        let result = displayedResult
        switch previewMode {
        case .original:
            pane(image: original, healEnabled: false).frame(height: 340)
        case .retouched:
            pane(image: result ?? original, healEnabled: spotMode && result != nil && !busy)
                .frame(height: 340)
        case .compare:
            if let result, result.size.width > 0, result.size.height > 0 {
                HStack(spacing: 8) {
                    labelledPane(title: "原图", image: original, healEnabled: false)
                    labelledPane(title: "精修", image: result, healEnabled: false)
                }.frame(height: 320)
            } else {
                pane(image: original, healEnabled: false).frame(height: 340)
            }
        }
    }

    private func labelledPane(title: String, image: UIImage, healEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            pane(image: image, healEnabled: healEnabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Aspect-fit preview with tap coordinates mapped back into the visible image
    /// rect, so `healSpot` receives normalised (0...1, y-down) coordinates that
    /// match what the user actually touched.
    private func pane(image: UIImage, healEnabled: Bool) -> some View {
        GeometryReader { geometry in
            let rect = fittedRect(image: image.size, in: geometry.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard healEnabled else { return }
                        let x = (location.x - rect.minX) / max(rect.width, 1)
                        let y = (location.y - rect.minY) / max(rect.height, 1)
                        guard (0...1).contains(x), (0...1).contains(y) else { return }
                        healSpot(at: CGPoint(x: x, y: y), in: image)
                    }
                if healEnabled {
                    VStack {
                        Spacer()
                        Text("点按小瑕疵局部修复")
                            .font(.caption2)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 14))
    }

    private func fittedRect(image: CGSize, in bounds: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let width = image.width * scale
        let height = image.height * scale
        return CGRect(x: (bounds.width - width) / 2,
                      y: (bounds.height - height) / 2,
                      width: width,
                      height: height)
    }

    // MARK: - QC panel

    private func qcPanel(_ report: RetouchQualityReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("质检报告").font(.headline)
                Spacer()
                Text(report.passed ? "通过" : "需复核")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(report.passed ? AppTheme.soft : Color.orange.opacity(0.18), in: Capsule())
            }
            Text(report.summary).font(.subheadline)
            if !orderedMetricKeys(for: report).isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(orderedMetricKeys(for: report), id: \.self) { key in
                        if let value = report.metrics[key] {
                            metricCell(key: key, value: value)
                        }
                    }
                }
            }
            Text("瑕疵：检测 \(spotsFound)／剩余 \(spotsRemaining)")
                .font(.footnote).foregroundStyle(.secondary)
            if let lastLook {
                Text("本次风格：\(lastLook.displayName)").font(.caption).foregroundStyle(.secondary)
            }
            if !report.notes.isEmpty {
                Text(report.notes.joined(separator: "；")).font(.caption).foregroundStyle(.secondary)
            }
            Text("局部修复不重新计算质检指标；需要刷新请再次执行本地精修。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .appCard()
    }

    private func orderedMetricKeys(for report: RetouchQualityReport) -> [String] {
        let known = CommercialRetouchView.metricOrder.filter { report.metrics[$0] != nil }
        let extra = report.metrics.keys
            .filter { !CommercialRetouchView.metricOrder.contains($0) }
            .sorted()
        return known + extra
    }

    private func metricCell(key: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metricLabel(key)).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%.3f", value))
                .font(.system(.footnote, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 10))
    }

    private func metricLabel(_ key: String) -> String {
        switch key {
        case "texture_retention": return "纹理保留"
        case "skin_tone_de": return "肤色 ΔE"
        case "skin_luma_shift": return "肤色明度偏移"
        case "clipping_skin": return "肤色裁切"
        case "clipping_full": return "整体裁切"
        case "seam_ratio": return "接缝比例"
        case "ssim": return "SSIM"
        case "blemish_clearance": return "瑕疵清除率"
        case "spots_before": return "检测瑕疵数"
        default: return key
        }
    }

    // MARK: - Job restore

    private func restore(_ id: UUID) {
        do {
            let data = try store.originalBytes(job: id)
            guard let image = UIImage(data: data) else { throw RetouchFailure.invalidImage }
            let revisions = try RetouchRecovery().validRevisions(job: id)
            originalData = data
            original = image
            jobID = id
            aiCalls = RetouchRecovery().hasReservedAICall(job: id) ? 1 : 0
            allowPaidCall = false
            localResult = nil; aiResult = nil; fusedResult = nil
            qualityReport = nil; spotsFound = 0; spotsRemaining = 0
            lastLook = nil; previewMode = .retouched; spotMode = false
            versionURLs = revisions.map { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CommercialRetouch").appendingPathComponent(id.uuidString).appendingPathComponent($0.filename) }
            exportURL = versionURLs.last
            selectedRevision = versionURLs.last
            status = "已恢复原图及 \(revisions.count) 个校验通过的版本；可选择分享历史版本。" + (aiCalls > 0 ? " 此任务已发起过一次 AI 调用，不会再次扣费调用。" : "")
        } catch { status = "恢复失败：\(error.localizedDescription)" }
    }

    // MARK: - Local run

    private func runLocal() {
        guard let original, let jobID else { return }
        busy = true
        defer { busy = false }
        do {
            let preset = RetouchPresetCatalog.find(presetID)
            let outcome = try pipeline.process(original, preset: preset, strength: strength)
            let url = try store.saveJPEG(outcome.image, job: jobID, label: "local")
            localResult = outcome.image
            selectedRevision = url
            exportURL = url
            if !versionURLs.contains(url) { versionURLs.append(url) }
            qualityReport = outcome.report
            spotsFound = outcome.spotsFound
            spotsRemaining = outcome.spotsRemaining
            lastLook = outcome.look
            previewMode = .retouched
            status = "已独立保存本地 JPEG（风格 \(outcome.look.displayName)，强度 \(String(format: "%.2f", strength)))。"
                + (outcome.report.passed ? "质量门禁通过；仍需人工审核身份与肤质。" : "质量门禁未通过，建议降低强度或改用更保守的预设。")
        } catch { status = "处理失败：\(error.localizedDescription)；原图仍保留" }
    }

    /// Blemish repair. Coordinates are normalised in displayed image space (y down),
    /// exactly what `pipeline.healSpot(_:at:)` expects.
    private func healSpot(at point: CGPoint, in image: UIImage) {
        guard let jobID, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let output = try pipeline.healSpot(image, at: point)
            let url = try store.saveJPEG(output, job: jobID, label: "local")
            localResult = output
            selectedRevision = url
            exportURL = url
            if !versionURLs.contains(url) { versionURLs.append(url) }
            if spotsRemaining > 0 { spotsRemaining -= 1 }
            status = "局部修复已保存为新版本；请放大检查皮肤纹理与边缘。质检指标仍对应上一次整图精修。"
        } catch { status = "局部修复失败：\(error.localizedDescription)" }
    }

    // MARK: - AI run

    @MainActor private func runAI(dual: Bool) async {
        guard let original, let jobID, let originalData, !busy, allowPaidCall, aiCalls < 1 else { return }
        let preset = RetouchPresetCatalog.find(presetID)
        guard preset.aiAllowed else { status = "此纪实预设禁止自动生成式修改，请使用本地模式"; return }
        let key = APIKeyStore.read(.seedream)
        let model = CloudConfiguration.seedreamModel
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "请先在设置中配置 Seedream API Key"; return }
        busy = true
        defer { busy = false; allowPaidCall = false }
        do {
            let base: UIImage
            if dual {
                if let cached = localResult {
                    base = cached
                } else {
                    let outcome = try pipeline.process(original, preset: preset, strength: strength)
                    let url = try store.saveJPEG(outcome.image, job: jobID, label: "local")
                    if !versionURLs.contains(url) { versionURLs.append(url) }
                    localResult = outcome.image
                    qualityReport = outcome.report
                    spotsFound = outcome.spotsFound
                    spotsRemaining = outcome.spotsRemaining
                    lastLook = outcome.look
                    base = outcome.image
                }
            } else {
                base = original
            }
            guard let jpeg = base.jpegData(compressionQuality: 0.94) else { throw RetouchFailure.invalidExport }
            let prompt = "专业摄影后期：\(preset.name)。保留所有人物、宠物和物品身份特征，保持原始构图、尺寸、面部五官、毛发花纹及自然皮肤纹理。只做克制的局部光影、肤色、细节优化；不要生成新物体、替换天空或重画五官。"
            guard try RetouchRecovery().reserveAICall(job: jobID) else {
                aiCalls = 1
                status = "此任务已发起过一次 AI 调用，不会重复请求。"
                return
            }
            aiCalls = 1
            status = "Seedream 请求进行中；原图与本地版本已安全保存。"
            let response = try await SeedreamClient().edit(jpeg: jpeg, prompt: prompt, key: key, model: model)
            let bytes = try await SeedreamClient().download(response.imageURL)
            guard let ai = UIImage(data: bytes) else { throw RetouchFailure.invalidImage }
            let aiURL = try store.saveJPEG(ai, job: jobID, label: "seedream")
            aiResult = ai
            if !versionURLs.contains(aiURL) { versionURLs.append(aiURL) }
            selectedRevision = aiURL
            exportURL = aiURL
            status = "AI 版本独立保存，待人工检查。"
            if dual {
                do {
                    let mask = try SafeFusion().conservativeMask(local: base, ai: ai)
                    let merged = try SafeFusion().blend(local: base, ai: ai, mask: mask)
                    let review = CommercialQualityGate().review(original: original, candidate: merged, aiModified: true)
                    guard review.decision != .rejected else { throw SafeFusion.Failure.renderFailed }
                    let url = try store.saveJPEG(merged, job: jobID, label: "fusion")
                    fusedResult = merged
                    if !versionURLs.contains(url) { versionURLs.append(url) }
                    selectedRevision = url
                    exportURL = url
                    status = "融合候选已保存，仍需人工审核；原图、本地版和 AI 版均保留。"
                } catch {
                    status = "自动融合拒绝：\(error.localizedDescription)。AI 版本已保存；本地版未受影响。"
                }
            }
            if !store.verifyOriginal(job: jobID, expected: originalData) {
                status += " 原图完整性校验异常，请停止交付。"
            }
        } catch { status = "AI 处理失败：\(error.localizedDescription)。原图和之前版本不受影响；不会自动重试扣费。" }
    }
}
