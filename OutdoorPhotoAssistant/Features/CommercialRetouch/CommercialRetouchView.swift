import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

// AI 修图建议的数据模型与生成逻辑已抽到 Core/CommercialRetouch/AIEditAdvisor.swift，
// 单张精修页与批量精修台共用同一套规则（避免两处阈值漂移）。

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

    // MARK: AI 修图建议状态
    @State private var advice: AIEditAdvice?
    @State private var aiPrompt = ""

    // MARK: Lightroom 核心阶段状态
    /// 总开关，默认开。关掉后 `RetouchPipeline` 完全不下发这一阶段。
    @AppStorage("lightroomCore") private var lightroomCore = true
    /// Look 强度倍率，0 = 关、1 = 标准、>1 更风格化。
    @AppStorage("lightroomAmount") private var lightroomAmount = 1.0
    /// 选中的导入预设 id（空 = 用内置 6 个风格表）。
    @AppStorage("lightroomImportedPresetID") private var lightroomPresetID = ""
    @State private var importedPresets: [LightroomPreset] = []
    @State private var showingPresetImporter = false
    @State private var presetImportMessage = ""

    private let pipeline = RetouchPipeline()
    private let store = RetouchVersionStore()

    /// Stable display order for the metrics the pipeline emits; any additional
    /// key the pipeline adds later is appended in sorted order instead of hidden.
    private static let metricOrder = [
        "texture_retention",
        "skin_tone_de",
        "skin_luma_shift",
        "skin_pixel_de_p95_info",
        "clipping_skin",
        "clipping_full",
        "seam_ratio",
        "ssim",
        "blemish_clearance",
        "spots_before"
    ]

    /// 身份保持约束：任何自定义提示词都会先拼上这段，避免长提示词把身份约束挤掉。
    private static let identityConstraint = "必须保持人物身份、五官、脸型、构图、尺寸完全不变；保留真实皮肤纹理与毛孔；禁止生成新物体、禁止替换天空、禁止重画五官。"

    /// 自定义提示词上限（字符），超出后截断，避免 Seedream 请求超限。
    private static let customPromptLimit = 900

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("单张精修").font(.title2.bold()).foregroundStyle(AppTheme.ink)
                        Text("先选照片，再选引擎。本地精修出结果后会立刻给出 AI 修图建议与可发送提示词；三个页签随时来回切换。")
                            .font(.subheadline).foregroundStyle(AppTheme.muted)
                    }

                    engineTabPicker

                    PhotosPicker(selection: $picker, matching: .images) {
                        Label("选择照片并智能识别", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity).padding(14)
                    }.buttonStyle(.borderedProminent)

                    Text(suggestion).font(.caption).foregroundStyle(.secondary)

                    if let original {
                        previewModePicker
                        previewArea(original: original)
                        Text(previewHint).font(.caption).foregroundStyle(.secondary)
                        enginePane
                    } else {
                        emptyPane
                    }

                    sharedResultSections
                }.padding(18)
            }.navigationTitle("智能精修").navigationBarTitleDisplayMode(.inline)
                .onAppear { recoverableJobs = RetouchRecovery().jobs() }
                .onChange(of: picker) { _, newValue in
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
                        advice = nil; aiPrompt = ""
                        do { jobID = try store.newJob(originalData: data) }
                        catch { status = "原图存档失败：\(error.localizedDescription)"; return }
                        let (recommended, message) = await pipeline.suggestPreset(image: image)
                        presetID = recommended.id
                        suggestion = "推荐：\(recommended.name)。\(message)"
                    }
                }
        }
    }

    // MARK: - 引擎页签

    /// 页面最顶端的三引擎页签：三个面板都常驻页面，切换不丢状态，任意方向来回。
    private var engineTabPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("精修引擎", selection: $engine) {
                Text("本地精修").tag(RetouchEngineChoice.local)
                Text("AI 修图").tag(RetouchEngineChoice.seedream)
                Text("双引擎").tag(RetouchEngineChoice.dual)
            }.pickerStyle(.segmented)

            Text(engineHint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var engineHint: String {
        switch engine {
        case .local:
            return "本地精修：只在本机执行、无 API 费用。完成后自动生成「AI 修图建议」和可直接发送的提示词，底部可一键去 AI 修图。"
        case .seedream:
            return "AI 修图：Seedream 云端生成，需要打开付费开关（每个任务最多 1 次）。顶部「← 回本地精修」随时返回。"
        case .dual:
            return "双引擎：① 先执行本地精修拿到建议；② 带着建议执行 AI。原图、本地版、AI 版、融合版互不覆盖。"
        }
    }

    private var engineEmptyHint: String {
        switch engine {
        case .local:
            return "选择照片后会自动推荐预设，可直接本地精修并得到 AI 修图建议。"
        case .seedream:
            return "选择照片后打开付费开关即可调用 AI 修图；也可先回本地精修拿建议。"
        case .dual:
            return "选择照片后先本地精修，再带着建议执行 AI。"
        }
    }

    private var emptyPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("先选择照片").font(.headline)
            Text(engineEmptyHint).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    @ViewBuilder
    private var enginePane: some View {
        switch engine {
        case .local:
            localPane()
        case .seedream:
            aiPane()
        case .dual:
            dualPane()
        }
    }

    // MARK: - 本地精修面板

    @ViewBuilder
    private func localPane() -> some View {
        presetStrengthSection()

        Button("执行本地精修并独立保存") { runLocal() }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        Text("仅在本机执行，无 API 费用。改动强度或预设后需重新执行；结果与建议会一起刷新。")
            .font(.caption).foregroundStyle(.secondary)

        if let qualityReport {
            qcPanel(qualityReport)
        }

        if let advice {
            adviceCard(advice)
        } else {
            Text("执行本地精修后，这里会出现逐条「AI 修图建议」和可直接发送的提示词。")
                .font(.caption).foregroundStyle(.secondary)
        }

        Button {
            goToAI()
        } label: {
            Label("→ 去 AI 修图", systemImage: "sparkles")
                .frame(maxWidth: .infinity).padding(8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy)

        Text(advice == nil ? "尚未生成建议：去 AI 面板后仍可用默认提示词。" : "已带上本地生成的 AI 修图建议、建议预设与建议强度。")
            .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: - AI 修图面板

    @ViewBuilder
    private func aiPane() -> some View {
        Button {
            engine = .local
            status = "已回到本地精修面板；本地结果与建议均保留。"
        } label: {
            Label("← 回本地精修", systemImage: "arrow.uturn.backward")
                .frame(maxWidth: .infinity).padding(8)
        }
        .buttonStyle(.bordered)

        if let advice {
            adviceCard(advice)
        }

        promptEditor
        presetStrengthSection()
        paidCallToggle

        Button("执行 AI 修图") { startAI(dual: false) }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !allowPaidCall || aiCalls >= 1)
        Text(aiCalls >= 1 ? "此任务已用过 1 次 AI 调用，不会重复扣费。" : "AI 调用会产生服务商费用；每个任务最多 1 次。")
            .font(.caption).foregroundStyle(.orange)

        NavigationLink("打开图库 · Seedream 独立入口") { GalleryView() }
            .buttonStyle(.bordered)
    }

    // MARK: - 双引擎面板

    @ViewBuilder
    private func dualPane() -> some View {
        Button("① 先执行本地精修") { runLocal() }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

        if let qualityReport {
            qcPanel(qualityReport)
        }

        if let advice {
            adviceCard(advice)
        } else {
            Text("先执行本地精修，这里会出现 AI 修图建议；② 会把建议、预设与强度一起带进 AI。")
                .font(.caption).foregroundStyle(.secondary)
        }

        presetStrengthSection()
        paidCallToggle

        Button("② 带着建议执行 AI") { startAI(dual: true) }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !allowPaidCall || aiCalls >= 1)
        Text("执行双引擎（先本地再按需 AI）：先保存本地版；AI 版单独保存，融合仅在极少量像素变化且同尺寸时尝试，否则提示人工复核。")
            .font(.caption).foregroundStyle(.orange)

        NavigationLink("打开图库 · Seedream 独立入口") { GalleryView() }
            .buttonStyle(.bordered)
    }

    // MARK: - 预设 / 强度 / 付费开关

    @ViewBuilder
    private func presetStrengthSection() -> some View {
        Picker("摄影预设", selection: $presetID) {
            ForEach(RetouchPresetCatalog.categories, id: \.self) { category in
                Section(category) {
                    ForEach(RetouchPresetCatalog.presets(for: category)) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
            }
        }.pickerStyle(.menu)

        Text("当前预设：\(RetouchPresetCatalog.find(presetID).name) · \(RetouchPresetCatalog.find(presetID).look.displayName)"
             + (RetouchPresetCatalog.find(presetID).aiAllowed ? "" : " · 此预设禁止 AI 生成式修改"))
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

        lightroomCoreSection
    }

    // MARK: - Lightroom 核心阶段

    /// Lightroom 核心色阶/曲线/HSL/清晰度：默认开启，可调强度，支持导入 .xmp 预设。
    private var lightroomCoreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Lightroom 核心阶段", systemImage: "slider.horizontal.below.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(lightroomCore ? "已启用" : "已关闭")
                    .font(.caption2)
                    .foregroundStyle(lightroomCore ? AppTheme.ink : .secondary)
            }
            Toggle("启用曲线 / HSL / 清晰度（ACR 顺序）", isOn: $lightroomCore)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Look 强度").font(.caption)
                    Spacer()
                    Text(String(format: "%.2f", lightroomAmount))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $lightroomAmount, in: 0...1.5, step: 0.05)
                    .accessibilityLabel("Lightroom Look 强度")
                    .disabled(!lightroomCore)
                Text("0 = 关闭，1.00 = 标准，>1 更风格化。内置 6 个风格表；导入 .xmp 预设后优先用预设参数。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Picker("Look 来源", selection: $lightroomPresetID) {
                Text("内置（跟随当前精修预设）").tag("")
                ForEach(importedPresets) { preset in
                    Text(preset.group.isEmpty ? preset.name : "\(preset.group) · \(preset.name)")
                        .tag(preset.id.uuidString)
                }
            }
            .pickerStyle(.menu)
            .disabled(!lightroomCore)

            HStack(spacing: 10) {
                Button {
                    showingPresetImporter = true
                } label: {
                    Label("导入 .xmp 预设", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                if !lightroomPresetID.isEmpty {
                    Button("用回内置") { lightroomPresetID = "" }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }

            if !presetImportMessage.isEmpty {
                Text(presetImportMessage).font(.caption2).foregroundStyle(.secondary)
            }
            if importedPresets.isEmpty {
                Text("把 Lightroom「预设 → 导出」得到的 .xmp 文件导进来即可，参数按 crs: 键逐项读取。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 14))
        .fileImporter(isPresented: $showingPresetImporter,
                      allowedContentTypes: [.xml, .data],
                      allowsMultipleSelection: true) { result in
            handlePresetImport(result)
        }
        .onAppear { importedPresets = LightroomPresetStore.shared.all() }
    }

    private func handlePresetImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            presetImportMessage = "导入失败：\(error.localizedDescription)"
        case .success(let urls):
            var imported = 0
            var failed = 0
            var firstName: String?
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let preset = try LightroomPresetStore.shared.importPreset(from: url)
                    imported += 1
                    if firstName == nil { firstName = preset.name }
                } catch {
                    failed += 1
                }
            }
            importedPresets = LightroomPresetStore.shared.all()
            RetouchPipeline.clearLightroomLookCache()
            if let firstName, imported == 1 {
                lightroomPresetID = importedPresets.first { $0.name == firstName }?.id.uuidString ?? lightroomPresetID
            }
            presetImportMessage = imported > 0
                ? "已导入 \(imported) 个预设" + (failed > 0 ? "，\(failed) 个无法识别" : "")
                : "没有识别到可用的 Lightroom 预设（需含 crs: 参数）"
        }
    }

    private var paidCallToggle: some View {
        Toggle("允许本次付费 Seedream 调用（最多 1 次）", isOn: $allowPaidCall)
    }

    /// 可编辑提示词：留空则 runAI 使用预设默认提示词。
    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 提示词（可编辑）").font(.subheadline.weight(.semibold))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $aiPrompt)
                    .font(.footnote)
                    .frame(minHeight: 110)
                    .padding(4)
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 10))
                if aiPrompt.isEmpty {
                    Text("留空则使用预设默认提示词")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            Text("发送时会自动在前面拼上身份保持约束；自定义内容超过 \(CommercialRetouchView.customPromptLimit) 字符会截断。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - 预览

    private var previewModePicker: some View {
        Picker("预览视图", selection: $previewMode) {
            ForEach(PreviewMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }.pickerStyle(.segmented)
    }

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
        case "skin_pixel_de_p95_info": return "肤色ΔE P95（信息）"
        case "clipping_skin": return "肤色裁切"
        case "clipping_full": return "整体裁切"
        case "seam_ratio": return "接缝比例"
        case "ssim": return "SSIM"
        case "blemish_clearance": return "瑕疵清除率"
        case "spots_before": return "检测瑕疵数"
        default: return key
        }
    }

    // MARK: - AI 修图建议

    // 生成逻辑已抽到 AIEditAdvisor（单张精修页与批量精修台共用同一套阈值，避免两处漂移）。
    // adviceCard / applyAdviceToAI / goToAI 继续只依赖 AIEditAdvice 的字段，未做改动。
    private func adviceCard(_ advice: AIEditAdvice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI 修图建议（\(advice.items.count) 条）").font(.headline)
                Spacer()
                Text(String(format: "建议强度 %.2f", advice.recommendedStrength))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(advice.headline).font(.subheadline)

            ForEach(advice.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.metric).font(.caption2.weight(.bold))
                    Text("现象：\(item.finding)").font(.caption)
                    Text("建议动作：\(item.action)").font(.caption)
                    Text("建议参数：\(item.parameter)").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 10))
            }

            Text("可直接发送的 AI 提示词（可编辑）").font(.caption.weight(.semibold))
            TextEditor(text: $aiPrompt)
                .font(.footnote)
                .frame(minHeight: 110)
                .padding(4)
                .scrollContentBackground(.hidden)
                .background(AppTheme.soft, in: RoundedRectangle(cornerRadius: 10))

            Text("建议预设：\(RetouchPresetCatalog.find(advice.recommendedPresetID).name) · 建议强度 \(String(format: "%.2f", advice.recommendedStrength))")
                .font(.caption2).foregroundStyle(.secondary)

            Button {
                applyAdviceToAI(advice)
            } label: {
                Text("带着建议去 AI 修图").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)

            Button {
                strength = advice.recommendedStrength
                runLocal()
            } label: {
                Text("按建议重跑本地精修").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(busy)

            Button {
                UIPasteboard.general.string = advice.prompt
                status = "提示词已复制"
            } label: {
                Text("复制提示词").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .appCard()
    }

    /// 「带着建议去 AI 修图」：建议、预设、强度一起带过去。
    private func applyAdviceToAI(_ advice: AIEditAdvice) {
        aiPrompt = advice.prompt
        presetID = advice.recommendedPresetID
        strength = advice.recommendedStrength
        engine = .seedream
        status = "已载入 \(advice.items.count) 条 AI 修图建议"
    }

    /// 本地面板底部跳转：带上已算好的建议。
    private func goToAI() {
        if let advice {
            aiPrompt = advice.prompt
            presetID = advice.recommendedPresetID
            strength = advice.recommendedStrength
            status = "已载入 \(advice.items.count) 条 AI 修图建议"
        } else {
            status = "尚未生成本地精修结果；先用默认提示词或回本地精修拿建议。"
        }
        engine = .seedream
    }

    // MARK: - 共享结果区

    @ViewBuilder
    private var sharedResultSections: some View {
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
            advice = nil; aiPrompt = ""
            versionURLs = revisions.map { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CommercialRetouch").appendingPathComponent(id.uuidString).appendingPathComponent($0.filename) }
            exportURL = versionURLs.last
            selectedRevision = versionURLs.last
            status = "已恢复原图及 \(revisions.count) 个校验通过的版本；可选择分享历史版本；需重新执行本地精修才会生成新的 AI 修图建议。" + (aiCalls > 0 ? " 此任务已发起过一次 AI 调用，不会再次扣费调用。" : "")
        } catch { status = "恢复失败：\(error.localizedDescription)" }
    }

    // MARK: - Local run

    private func runLocal() {
        guard let original, let jobID else { status = "先选择照片并等待原图存档完成"; return }
        guard !busy else { return }
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

            let generated = AIEditAdvisor.makeAdvice(report: outcome.report, look: outcome.look, presetID: preset.id,
                                       strength: strength, spotsFound: outcome.spotsFound,
                                       spotsRemaining: outcome.spotsRemaining)
            advice = generated
            aiPrompt = generated.prompt

            status = "已独立保存本地 JPEG（风格 \(outcome.look.displayName)，强度 \(String(format: "%.2f", strength)))。已生成 \(generated.items.count) 条 AI 修图建议。"
                + (outcome.report.passed
                    ? "质量门禁通过；仍需人工审核身份与肤质。"
                    : "质量门禁未通过，已按不通过项生成 AI 纠正清单，也可「按建议重跑本地精修」。")

            // 诊断包记录点：最近一次本地精修的质检结果与 Lightroom 核心参数。
            DiagnosticsCenter.shared.recordRetouch(RetouchDiagnostics(recordedAt: Date(), presetID: presetID, look: outcome.look.displayName, strength: strength, passed: outcome.report.passed, metrics: outcome.report.metrics, notes: outcome.report.notes, lightroomCore: (UserDefaults.standard.object(forKey: "lightroomCore") as? Bool) ?? true, lightroomAmount: (UserDefaults.standard.object(forKey: "lightroomAmount") as? Double) ?? 1.0, imageSize: "\(Int(outcome.image.size.width))x\(Int(outcome.image.size.height))"))
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

    /// 统一入口：付费开关 / 重复扣费 / 忙碌状态都在这里拦，避免静默无反应。
    private func startAI(dual: Bool) {
        guard original != nil else { status = "先选择照片"; return }
        guard !busy else { return }
        guard allowPaidCall else {
            status = "请先打开「允许本次付费 Seedream 调用（最多 1 次）」开关。"
            return
        }
        guard aiCalls < 1 else {
            status = "此任务已发起过一次 AI 调用，不会重复请求。"
            return
        }
        Task { await runAI(dual: dual) }
    }

    /// 自定义提示词拼上身份保持约束；超长截断到 900 字符。
    private func composedPrompt(preset: RetouchPreset) -> String {
        let custom = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else {
            return "专业摄影后期：\(preset.name)。保留所有人物、宠物和物品身份特征，保持原始构图、尺寸、面部五官、毛发花纹及自然皮肤纹理。只做克制的局部光影、肤色、细节优化；不要生成新物体、替换天空或重画五官。"
        }
        let clipped = String(custom.prefix(CommercialRetouchView.customPromptLimit))
        return CommercialRetouchView.identityConstraint + "\n" + clipped
    }

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
                    advice = AIEditAdvisor.makeAdvice(report: outcome.report, look: outcome.look, presetID: preset.id,
                                        strength: strength, spotsFound: outcome.spotsFound,
                                        spotsRemaining: outcome.spotsRemaining)
                    base = outcome.image
                }
            } else {
                base = original
            }
            guard let jpeg = base.jpegData(compressionQuality: 0.94) else { throw RetouchFailure.invalidExport }
            let prompt = composedPrompt(preset: preset)
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
                // 新融合器：分块投票（结构相关 + 块内 ΔE），不再要求「全图变化 <8%」——
                // 那是旧实现被拒的真正原因。判定与理由由 Decision 回传，全部可读。
                // 纪实/商品/建筑这类硬约束类别不给「生成式改写」额度，投票权重再打对折。
                let allowsGenerative = preset.aiAllowed
                    && !["商品摄影", "建筑与室内", "文档与翻拍"].contains(preset.category)
                // 有主体遮罩就传：背景块权重会被压到 0.35，防止 AI 顺手改背景。
                var subjectMaskImage: UIImage?
                if let cg = base.cgImage {
                    let fusedContext = CIContext()
                    let input = CIImage(cgImage: cg)
                    if let mask = RetouchBackgroundEngine(context: fusedContext)
                        .subjectMask(for: input, geometry: nil, context: fusedContext),
                       let maskCG = fusedContext.createCGImage(mask, from: input.extent) {
                        subjectMaskImage = UIImage(cgImage: maskCG)
                    }
                }
                let decision = SafeFusion().fuse(local: base, ai: ai,
                                                 subjectMask: subjectMaskImage,
                                                 allowsGenerative: allowsGenerative)
                if decision.applied, let merged = decision.merged {
                    let review = CommercialQualityGate().review(original: original,
                                                                candidate: merged,
                                                                aiModified: true)
                    if review.decision == .rejected {
                        status = "融合已生成但复核未过："
                            + (review.findings.first ?? "结构/肤色不达标")
                            + "。AI 版与本地版均保留。"
                    } else {
                        do {
                            let url = try store.saveJPEG(merged, job: jobID, label: "fusion")
                            fusedResult = merged
                            if !versionURLs.contains(url) { versionURLs.append(url) }
                            selectedRevision = url
                            exportURL = url
                            status = (decision.notes.first ?? "融合候选已保存")
                                + String(format: "（采纳 %d/%d 块 · 平均 ΔE %.1f · 结构 %.2f）",
                                         Int(decision.acceptedRatio * Double(decision.totalTiles)),
                                         decision.totalTiles, decision.meanDeltaE, decision.structureKept)
                                + "；仍需人工审核，原图/本地版/AI 版均保留。"
                        } catch {
                            status = "融合结果保存失败：\(error.localizedDescription)。AI 版本已保存；本地版未受影响。"
                        }
                    }
                } else {
                    // 不采纳也把「为什么」写清楚，AI 版仍作为独立版本保存
                    status = "自动融合未采纳："
                        + (decision.reasons.first ?? "结构与改动量超出保守融合范围")
                        + "。AI 版已保存；本地版未受影响。"
                }
            }
            if !store.verifyOriginal(job: jobID, expected: originalData) {
                status += " 原图完整性校验异常，请停止交付。"
            }
        } catch { status = "AI 处理失败：\(error.localizedDescription)。原图和之前版本不受影响；不会自动重试扣费。" }
    }
}
