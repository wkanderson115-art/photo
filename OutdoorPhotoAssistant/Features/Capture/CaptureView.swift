import SwiftUI
import UIKit

struct CaptureView: View {
    let isSelected: Bool
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var camera: CameraService
    @EnvironmentObject var motion: MotionService
    @EnvironmentObject var analyzer: FrameAnalyzer
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var library: PhotoLibraryService

    @AppStorage("showGrid") private var showGrid = true
    @AppStorage("autoReview") private var autoReview = true
    @AppStorage("autoScene") private var autoScene = true
    @AppStorage("autoFilter") private var autoFilter = true
    @AppStorage("autoComposition") private var autoComposition = true
    @AppStorage("autoCapture") private var autoCapture = false
    @AppStorage("saveBoth") private var saveBoth = true
    @AppStorage("highQuality") private var highQuality = false

    @State private var manualScene = "风景"
    @State private var manualFilter: PhotoFilter = .natural
    @State private var compositionStyle = "自然"
    @State private var countdown = 0
    @State private var autoShotPending = false
    @State private var autoShotTask: Task<Void, Never>?
    @State private var autoLensTask: Task<Void, Never>?
    @State private var lastAutoScene = ""
    @State private var showReview = false
    @State private var reviewShot: CapturedPhoto?
    @State private var reviewStyled: UIImage?
    @State private var reviewOptions = PhotoRenderOptions()
    @State private var reviewIsBest = false
    @State private var bestScore = 0
    @State private var activeRenders = 0
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var lastToken = UUID()

    private let scenes = ["人物", "风景", "建筑", "日落", "夜景", "花草", "海边", "汽车", "自拍"]
    private let styles = ["自然", "电影", "主体"]

    private var effectiveScene: String { autoScene ? analyzer.detectedScene : manualScene }
    private var effectiveFilter: PhotoFilter { autoFilter ? analyzer.recommendedFilter : manualFilter }
    private var effectiveGrade: ColorGrade { autoFilter ? analyzer.autoGrade : ColorGrade() }

    var body: some View {
        ZStack {
            CameraPreview(camera: camera)
                .ignoresSafeArea()

            CompositionOverlay(subject: analyzer.subject,
                               motion: motion,
                               scene: effectiveScene,
                               showGrid: showGrid,
                               horizonAngle: analyzer.horizonAngle,
                               framingHint: analyzer.framingHint,
                               frameAspectRatio: analyzer.frameAspectRatio)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 10)
                DirectorCard(analyzer: analyzer,
                             camera: camera,
                             countdown: countdown,
                             autoCapture: autoCapture)
                QualityCard(analyzer: analyzer)
                controls
            }

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.bottom, 190)
                }
                .transition(.opacity)
            }

            if camera.authorizationDenied {
                PermissionHint(title: "需要相机权限",
                               message: "请在系统设置中允许「户外拍照助手」使用相机。",
                               actionTitle: "打开设置") {
                    self.openAppSettings()
                }
            } else if let error = camera.errorMessage {
                VStack {
                    Text(error)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.75))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.top, 90)
            }
        }
        .onAppear {
            guard self.isSelected else { return }
            self.camera.setHighQualityMode(self.highQuality)
            self.camera.start()
            self.motion.start()
            self.location.start()
            self.analyzer.setPeriod(self.location.periodText)
        }
        .onDisappear {
            self.camera.stop()
            self.motion.stop()
            self.location.stop()
            self.autoShotTask?.cancel()
            self.autoLensTask?.cancel()
            self.toastTask?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && self.isSelected {
                self.camera.start()
                self.motion.start()
                self.location.start()
            } else {
                self.camera.stop()
                self.motion.stop()
                self.location.stop()
                self.autoShotTask?.cancel()
                self.autoLensTask?.cancel()
            }
        }
        .onChange(of: isSelected) { _, selected in
            if selected && self.scenePhase == .active {
                self.camera.start()
                self.motion.start()
                self.location.start()
            } else {
                self.camera.stop()
                self.motion.stop()
                self.location.stop()
                self.autoShotTask?.cancel()
                self.autoLensTask?.cancel()
            }
        }
        .onChange(of: camera.photoToken) { _, _ in
            self.processLatestPhoto()
        }
        .onChange(of: analyzer.brightness) { _, value in
            self.camera.applyExposureCompensation(brightness: value)
        }
        .onChange(of: analyzer.detectedScene) { _, scene in
            self.handleSceneChange(scene)
        }
        .onChange(of: analyzer.autoCaptureReady) { _, ready in
            if ready { self.startCountdown() }
        }
        .onChange(of: location.periodText) { _, period in
            self.analyzer.setPeriod(period)
        }
        .onChange(of: autoCapture) { _, enabled in
            if !enabled {
                self.autoShotTask?.cancel()
                self.countdown = 0
                self.autoShotPending = false
            } else if self.analyzer.autoCaptureReady {
                self.startCountdown()
            }
        }
        .onChange(of: highQuality) { _, value in
            self.camera.setHighQualityMode(value)
        }
        .onChange(of: library.lastSaveError) { _, error in
            if let error {
                self.showToast("保存失败：\(error)")
            }
        }
        .sheet(isPresented: $showReview) {
            if let shot = self.reviewShot, let styled = self.reviewStyled {
                ReviewView(shot: shot,
                           styledImage: styled,
                           renderOptions: self.reviewOptions,
                           analyzer: self.analyzer,
                           motion: self.motion,
                           scene: self.effectiveScene,
                           isSessionBest: self.reviewIsBest)
                    .environmentObject(self.library)
            }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(self.scenes, id: \.self) { scene in
                    Button(scene) { self.manualScene = scene }
                }
            } label: {
                Label(self.autoScene ? "自动·\(self.effectiveScene)" : self.manualScene,
                      systemImage: "camera.metering.center.weighted")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(location.periodText.isEmpty ? "光线判断中" : location.periodText)
                    .font(.caption.weight(.bold))
                Text("识别 \(Int(analyzer.sceneConfidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Button {
                self.camera.switchCamera()
            } label: {
                Image(systemName: "camera.rotate")
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    // MARK: - 控制区

    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Label(effectiveFilter.rawValue, systemImage: effectiveFilter.icon)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())

                    if !autoFilter {
                        ForEach(PhotoFilter.allCases) { item in
                            Button(item.rawValue) { self.manualFilter = item }
                                .font(.caption)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(self.manualFilter == item ? Color.white : Color.black.opacity(0.45))
                                .foregroundStyle(self.manualFilter == item ? Color.black : Color.white)
                                .clipShape(Capsule())
                        }
                    } else {
                        Text(analyzer.gradeSummary)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal)
            }

            HStack(spacing: 18) {
                ForEach(self.camera.availableZooms, id: \.self) { value in
                    Button {
                        self.camera.setZoom(value)
                    } label: {
                        Text(String(format: "%.1f×", value))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(abs(self.camera.zoom - value) < 0.01 ? Color.yellow : Color.white)
                }

                Spacer()

                Button {
                    // 手动快门 = 立即拍摄，不再经过"智能快门"延迟
                    self.camera.capture()
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 72, height: 72)
                        Circle().stroke(.black.opacity(0.22), lineWidth: 4).frame(width: 62, height: 62)
                        if self.activeRenders > 0 {
                            ProgressView().tint(.black)
                        }
                    }
                }
                .disabled(!camera.isRunning || activeRenders > 0)

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f×", camera.zoom)).font(.headline)
                    Text(effectiveFilter.rawValue).font(.caption2)
                    Text(camera.apertureText).font(.caption2)
                    Text(camera.depthSupported ? "深度 ✓" : "无深度").font(.caption2)
                }
                .frame(width: 92, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                toggle("AI取景", $autoComposition)
                toggle("自动滤镜", $autoFilter)
                toggle("自动拍", $autoCapture)
                toggle("存原片", $saveBoth)
                toggle("高清", $highQuality)
            }
            .font(.caption2)
            .padding(.bottom, 7)

            HStack(spacing: 7) {
                ForEach(self.styles, id: \.self) { style in
                    Button(style) { self.compositionStyle = style }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(self.compositionStyle == style ? Color.white : Color.white.opacity(0.12))
                        .foregroundStyle(self.compositionStyle == style ? Color.black : Color.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.black.opacity(0.5))
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
        } label: {
            Text((value.wrappedValue ? "✓ " : "") + title)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(value.wrappedValue ? Color.white.opacity(0.85) : Color.white.opacity(0.12))
                .foregroundStyle(value.wrappedValue ? Color.black : Color.white)
                .clipShape(Capsule())
        }
    }

    // MARK: - 拍照结果处理（全部在后台渲染）

    private func processLatestPhoto() {
        guard camera.photoToken != lastToken else { return }
        lastToken = camera.photoToken
        guard let shot = camera.latestPhoto else { return }

        self.activeRenders += 1

        let options = PhotoRenderOptions(
            filter: effectiveFilter,
            grade: effectiveGrade,
            style: compositionStyle,
            beauty: (effectiveScene == "人物" || effectiveScene == "自拍") ? PortraitBeautySettings() : nil
        )
        let exposure = analyzer.qualityExposure
        let composition = analyzer.compositionScore
        let sharpness = analyzer.qualitySharpness
        let wantsReview = autoReview
        let keepsOriginal = saveBoth
        let scene = effectiveScene

        DispatchQueue.global(qos: .userInitiated).async {
            let styled = PhotoPostProcessor.render(original: shot.image, options: options)
            let score = Int((Double(composition) * 0.45
                             + Double(exposure) * 0.25
                             + Double(sharpness) * 0.30).rounded())
            DispatchQueue.main.async {
                self.activeRenders = max(0, self.activeRenders - 1)
                guard let styled else {
                    self.showToast("图像处理失败")
                    return
                }
                self.finish(shot: shot,
                            styled: styled,
                            score: score,
                            scene: scene,
                            options: options,
                            wantsReview: wantsReview,
                            keepsOriginal: keepsOriginal)
            }
        }
    }

    private func finish(shot: CapturedPhoto,
                        styled: UIImage,
                        score: Int,
                        scene: String,
                        options: PhotoRenderOptions,
                        wantsReview: Bool,
                        keepsOriginal: Bool) {
        let isBest = score >= bestScore
        if isBest { self.bestScore = score }

        self.library.saveShot(originalData: shot.originalData,
                              styledImage: styled,
                              keepOriginal: keepsOriginal) { success in
            if success {
                self.showToast("已保存到相册")
            } else {
                self.showToast("保存失败：\(self.library.lastSaveError ?? "未知错误")")
            }
        }

        if wantsReview {
            self.reviewShot = shot
            self.reviewStyled = styled
            self.reviewOptions = options
            self.reviewIsBest = isBest
            self.showReview = true
        }
        _ = scene
    }

    private func showToast(_ message: String) {
        self.toast = message
        self.toastTask?.cancel()
        self.toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { self.toast = nil }
        }
    }

    // MARK: - 自动取景 / 自动拍摄

    private func handleSceneChange(_ scene: String) {
        guard autoScene, autoComposition, camera.cameraPosition == .back else { return }
        guard scene != lastAutoScene else { return }
        lastAutoScene = scene
        autoLensTask?.cancel()
        // 防抖 1.2 秒：场景抖动时不要反复重配 session
        self.autoLensTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            let target = CGFloat(self.analyzer.recommendedZoom)
            if abs(self.camera.zoom - target) > 0.01 {
                self.camera.setZoom(target)
            }
        }
    }

    private func startCountdown() {
        guard autoCapture, !autoShotPending else { return }
        autoShotPending = true
        autoShotTask?.cancel()
        self.autoShotTask = Task { @MainActor in
            for value in [3, 2, 1] {
                self.countdown = value
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled {
                    self.countdown = 0
                    self.autoShotPending = false
                    return
                }
            }
            self.countdown = 0

            let held = self.analyzer.autoCaptureHeld
            let decision = SmartShutterEngine.decide(stability: self.motion.stabilityScore,
                                                     isStable: self.motion.isStable,
                                                     exposureScore: self.analyzer.qualityExposure,
                                                     sharpnessScore: self.analyzer.qualitySharpness)
            if self.autoCapture && held && decision.action == .shootNow {
                self.camera.capture()
                self.showToast("自动拍摄：\(decision.reason)")
            } else {
                self.showToast(held ? decision.reason : "构图已变化，本次未自动拍摄")
            }
            self.autoShotPending = false
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 子视图

private struct DirectorCard: View {
    @ObservedObject var analyzer: FrameAnalyzer
    @ObservedObject var camera: CameraService
    let countdown: Int
    let autoCapture: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: analyzer.autoCaptureReady ? "checkmark.seal.fill" : "wand.and.stars")
                Text(analyzer.directorTitle).font(.headline)
                Spacer()
                Text("\(analyzer.compositionScore)").font(.headline.monospacedDigit())
            }
            Text(countdown > 0 ? "自动拍摄倒计时：\(countdown)" : analyzer.directorInstruction)
                .font(.subheadline)

            HStack(spacing: 8) {
                Label(camera.cameraEngineSummary, systemImage: "cpu")
                if camera.lowLightBoostActive {
                    Label("低光增强", systemImage: "moon.stars.fill")
                }
                if camera.hardwareHDRActive {
                    Label("硬件HDR", systemImage: "sun.max.fill")
                }
                if autoCapture {
                    Text(analyzer.autoCaptureReason)
                        .foregroundStyle(analyzer.autoCaptureReady ? Color.green : Color.white.opacity(0.7))
                }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.78))

            HStack(spacing: 12) {
                Label(analyzer.lightAdvice, systemImage: "sun.max")
                Spacer()
                Label(String(format: "建议 %.1f×", analyzer.recommendedZoom), systemImage: "camera.aperture")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.66))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal)
    }
}

private struct QualityCard: View {
    @ObservedObject var analyzer: FrameAnalyzer

    var body: some View {
        HStack(spacing: 10) {
            self.quality("曝光", analyzer.qualityExposure)
            self.quality("构图", analyzer.qualityComposition)
            self.quality("清晰", analyzer.qualitySharpness)
            Spacer()
            Text(analyzer.qualityLevel).font(.caption.weight(.bold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.46))
    }

    private func quality(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.caption.weight(.bold))
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }
}

private struct PermissionHint: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text(title).font(.headline)
            Text(message).font(.footnote).multilineTextAlignment(.center)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(32)
    }
}
