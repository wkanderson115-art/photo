import SwiftUI
import UIKit

struct ReviewView: View {
    let shot: CapturedPhoto
    let styledImage: UIImage
    let renderOptions: PhotoRenderOptions
    @ObservedObject var analyzer: FrameAnalyzer
    @ObservedObject var motion: MotionService
    let scene: String
    let isSessionBest: Bool

    @EnvironmentObject private var library: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    @AppStorage("directorLearning") private var directorLearning = true
    @State private var recordedFeedback = false
    @State private var previewingOriginal = false
    @State private var skin = 0.10
    @State private var faceDepth = 0.0
    @State private var faceSlim = 0.0
    @State private var eyeLift = 0.04
    @State private var environmentBlend = 0.16

    @State private var preview: UIImage?
    @State private var renderToken = UUID()
    @State private var saving = false
    @State private var rendering = false
    @State private var status: String?

    @State private var aesthetics: Double?
    @State private var composition = 0
    @State private var photoHorizon = 0.0
    @State private var photoSubject = SubjectInfo()
    @State private var selectedFilter: PhotoFilter = .natural
    @State private var filterStrength = 0.55
    @State private var blurStrength = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                previewSection
                if shot.depthMask != nil {
                    depthSection
                }
                metrics
                directorReview
                filterControls
                beautyControls
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom)
                }
            }
            .navigationTitle("照片分析与人像优化")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("原片") {
                        self.renderToken = UUID()
                        self.rendering = false
                        self.previewingOriginal = true
                        self.preview = self.shot.image
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "保存中…" : "保存成片") {
                        self.save()
                    }
                    .disabled(saving || rendering)
                }
            }
            .task {
                self.selectedFilter = self.renderOptions.filter
                self.filterStrength = self.renderOptions.filterStrength
                self.render()
                let image = self.styledImage
                self.analyzer.analyzePhoto(image) { aesthetic, score, horizon, subjectInfo in
                    DispatchQueue.main.async {
                        self.aesthetics = aesthetic
                        self.composition = score
                        self.photoHorizon = horizon
                        self.photoSubject = subjectInfo
                    }
                }
            }
            .onDisappear {
                self.renderToken = UUID()
            }
        }
    }

    // MARK: - 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自然人像优化").font(.headline)
            Image(uiImage: preview ?? styledImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topLeading) {
                    Label("小幅度调整，保留真实纹理", systemImage: "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(10)
                }
            Text("美肤、脸型、眼神与人景色彩融合都是小幅度调整，强度有上限。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var depthSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自然背景虚化").font(.headline)
            slider("虚化强度", $blurStrength, 0...1)
            Text("默认保留真实场景；只在有人像遮罩时启用轻度背景模糊，不改变人物大小。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
        .onChange(of: blurStrength) { _, _ in self.render() }
    }

    private var filterControls: some View {
        VStack(alignment: .leading) {
            Picker("滤镜", selection: $selectedFilter) {
                ForEach(PhotoFilter.allCases) { item in Text(item.rawValue).tag(item) }
            }
            slider("滤镜强度", $filterStrength, 0...1)
            Text("取景画面为原始预览，拍后显示滤镜成片。强度为零保留原始色彩。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
        .onChange(of: selectedFilter) { _, _ in self.render() }
        .onChange(of: filterStrength) { _, _ in self.render() }
    }

    // MARK: - 指标

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("拍后复盘").font(.title2.bold())
                Spacer()
                Text(scene).foregroundStyle(.secondary)
            }
            if isSessionBest {
                Label("本次拍摄最佳", systemImage: "trophy.fill")
                    .font(.headline)
                    .foregroundStyle(.yellow)
            }
            self.metric("AI 审美", aesthetics.map { String(format: "%.0f/100", ($0 + 1) * 50) } ?? "分析中")
            self.metric("构图", composition > 0 ? "\(composition)/100" : "分析中")
            self.metric("水平", abs(photoHorizon) < 0.05 ? "良好" : "建议校正")
            self.metric("稳定", motion.isStable ? "良好" : "拍摄时注意稳定")
            self.metric("主体", photoSubject.type == "未知" ? "未识别" : photoSubject.type)
            self.metric("景深", shot.depthPortrait == nil ? "未生成" : "已生成")
        }
        .padding()
    }

    private var directorReview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导演复盘与偏好学习").font(.title3.bold())
            ForEach(Array(renderOptions.directorEvidence.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.domain + " · " + item.rule).font(.headline)
                    Text(item.observation).font(.caption).foregroundStyle(.secondary)
                    Text(item.action).font(.subheadline)
                }
            }
            if let context = renderOptions.directorContext {
                if recordedFeedback {
                    Label("本次反馈已保存在本机", systemImage: "checkmark.circle")
                } else {
                    Button("喜欢这个效果，让导演记住") { learn(context, feedback: "喜欢效果") }
                        .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    HStack {
                        Button("主体太小") { learn(context, feedback: "主体太小") }
                        Button("主体太大") { learn(context, feedback: "主体太大") }
                    }.buttonStyle(.bordered)
                        .disabled(!context.automaticFraming || context.subjectFraction <= 0)
                }
                Text(directorLearning ? "反馈会调整同类场景的主体占比、滤镜及强度；至少3次相关反馈后采用偏好。" : "偏好学习已关闭，可在设置中开启。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("本次未使用导演决策，没有可学习的取景记录。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding().disabled(!directorLearning || rendering)
    }

    private func learn(_ context: DirectorLearningContext, feedback: String) {
        guard directorLearning, !recordedFeedback, !rendering else { return }
        DirectorPreferenceStore.shared.learn(context: context, filter: previewingOriginal ? "自然" : selectedFilter.rawValue,
                                             strength: previewingOriginal ? 0 : filterStrength, framingFeedback: feedback)
        recordedFeedback = true
    }

    // MARK: - 美颜控制

    private var beautyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("美颜美肤 · 面部微调整").font(.title3.bold())
            slider("自然美肤", $skin, 0...0.55)
            slider("面部立体", $faceDepth, 0...0.35)
            slider("轻微瘦脸", $faceSlim, 0...0.30)
            slider("眼神提亮", $eyeLift, 0...0.20)
            slider("人景融合", $environmentBlend, 0...0.50)

            Button("恢复自然") {
                self.skin = 0.10
                self.faceDepth = 0
                self.faceSlim = 0
                self.eyeLift = 0.04
                self.environmentBlend = 0.16
                self.render()
            }
            .buttonStyle(.bordered)

            Text("面部微调只在检测到人脸时生效；强度有上限，避免脸型失真或塑料皮肤。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onChange(of: skin) { _, _ in self.render() }
        .onChange(of: faceDepth) { _, _ in self.render() }
        .onChange(of: faceSlim) { _, _ in self.render() }
        .onChange(of: eyeLift) { _, _ in self.render() }
        .onChange(of: environmentBlend) { _, _ in self.render() }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f", value.wrappedValue * 100))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - 渲染与保存

    private func render() {
        self.previewingOriginal = false
        let token = UUID()
        self.renderToken = token
        self.rendering = true
        var options = renderOptions
        options.filter = selectedFilter
        options.filterStrength = filterStrength
        // Manual changes must not retain scene-specific color grading from another filter.
        if selectedFilter != renderOptions.filter { options.grade = ColorGrade(); options.style = "自然" }
        options.beauty = PortraitBeautySettings(skin: skin,
                                                clarity: 0.08,
                                                faceDepth: faceDepth,
                                                faceSlim: faceSlim,
                                                eyeLift: eyeLift,
                                                environmentBlend: environmentBlend)
        let mask = shot.depthMask
        let blur = blurStrength
        let original = shot.image
        let fallback = styledImage
        // 150ms 防抖：连续拖动滑杆时取消旧渲染，避免处理堆积
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard self.renderToken == token else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let colored = PhotoPostProcessor.render(original: original, options: options)
                let rendered = colored.flatMap { DepthPortraitProcessor.apply(image: $0, mask: mask, strength: blur) }
                DispatchQueue.main.async {
                    guard self.renderToken == token else { return }
                    self.preview = rendered ?? fallback
                    self.rendering = false
                }
            }
        }
    }

    private func save() {
        let output = preview ?? styledImage
        self.saving = true
        self.library.saveShot(originalData: shot.originalData,
                              styledImage: output,
                              keepOriginal: false, photoID: shot.id) { success in
            self.saving = false
            if success {
                self.status = "已保存成片到图库"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.dismiss()
                }
            } else {
                self.status = self.library.lastSaveError ?? "保存失败"
            }
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
