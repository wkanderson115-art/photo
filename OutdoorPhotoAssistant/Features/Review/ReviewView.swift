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

    @State private var skin = 0.22
    @State private var faceDepth = 0.08
    @State private var faceSlim = 0.05
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
    @State private var parallax: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                previewSection
                if shot.depthMask != nil {
                    depthSection
                }
                metrics
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
            Text("3D 人像与景色微动").font(.headline)
            ZStack {
                Image(uiImage: preview ?? styledImage).resizable().scaledToFit()
                if let mask = shot.depthMask {
                    Image(uiImage: preview ?? styledImage)
                        .resizable()
                        .scaledToFit()
                        .mask(Image(uiImage: mask).resizable().scaledToFit())
                        .offset(x: parallax)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        self.parallax = max(-20, min(20, value.translation.width * 0.12))
                    }
                    .onEnded { _ in
                        withAnimation(.spring()) { self.parallax = 0 }
                    }
            )
            Text("左右轻拖可观察空间层次。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 8)
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
                self.skin = 0.22
                self.faceDepth = 0.08
                self.faceSlim = 0.05
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
        let token = UUID()
        self.renderToken = token
        self.rendering = true
        var options = renderOptions
        options.beauty = PortraitBeautySettings(skin: skin,
                                                clarity: 0.08,
                                                faceDepth: faceDepth,
                                                faceSlim: faceSlim,
                                                eyeLift: eyeLift,
                                                environmentBlend: environmentBlend)
        let original = shot.image
        let fallback = styledImage
        // 150ms 防抖：连续拖动滑杆时取消旧渲染，避免处理堆积
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard self.renderToken == token else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let rendered = PhotoPostProcessor.render(original: original, options: options)
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
                              keepOriginal: false) { success in
            self.saving = false
            if success {
                self.status = "已保存成片到相册"
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
