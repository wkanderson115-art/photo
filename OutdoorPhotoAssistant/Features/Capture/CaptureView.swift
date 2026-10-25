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
    @AppStorage("autoCapture") private var autoCapture = true
    @AppStorage("saveBoth") private var saveBoth = true
    @AppStorage("highQuality") private var highQuality = true

    @AppStorage("directorLearning") private var directorLearning = true
    @AppStorage("autoDirector") private var autoDirector = true
    @AppStorage("directorFraming") private var directorFraming = "自动"
    @AppStorage("directorComposition") private var directorComposition = "自动"
    @State private var directorController = DirectorController()
    @State private var showZoomControl = false
    @State private var pinchStartZoom: CGFloat?
    @State private var sliderZoom: Double?
    @AppStorage("portraitDepth") private var portraitDepth = false
    @State private var showingSettings = false
    @AppStorage("autoZoom") private var autoZoom = true
    @State private var lastManualZoom = Date.distantPast
    @AppStorage("realtimeEffects") private var realtimeEffects = true
    @AppStorage("liveBeauty") private var liveBeauty = true
    @AppStorage("liveBeautyStrength") private var liveBeautyStrength = 0.16
    @AppStorage("filterStrength") private var filterStrength = 0.55
    @State private var shotMetrics: (exposure: Int, sharpness: Int, composition: Int)?
    @State private var captureOptions: PhotoRenderOptions?
    @AppStorage("manualScene") private var manualScene = "风景"
    @AppStorage("manualFilter") private var manualFilterName = "自然"
    private var manualFilter: PhotoFilter { PhotoFilter(rawValue: manualFilterName) ?? .natural }
    @AppStorage("compositionStyle") private var compositionStyle = "自然"
    @State private var autoCaptureArmed = true
    @State private var readySince: Date?
    @State private var readyBox: CGRect = .zero
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


    private var effectiveScene: String { autoScene ? analyzer.detectedScene : manualScene }
    private var effectiveFilter: PhotoFilter {
        guard autoFilter else { return manualFilter }
        if autoDirector { return .natural } // Preserve scene hues; adaptive grade supplies vividness.
        guard !autoScene || analyzer.sceneConfidence >= 0.65 else { return .natural }
        return PhotoFilter.recommended(scene: effectiveScene, brightness: analyzer.brightness, period: location.periodText)
    }
    private var effectiveGrade: ColorGrade {
        guard autoFilter, !autoScene || analyzer.sceneConfidence >= 0.65 else { return ColorGrade() }
        var grade = ColorGrade.automatic(scene: effectiveScene, brightness: analyzer.brightness,
                                         period: location.periodText, confidence: autoScene ? analyzer.sceneConfidence : 1)
        if autoDirector {
            let evidence = analyzer.directorObservation
            grade.temperature *= evidence.personCount > 0 ? 0 : 0.5
            let measured = evidence.saturation
            let person = evidence.personCount > 0
            grade.saturation = measured > 0.48 ? 1.02 : measured < 0.12 ? 1.04 : person ? 1.08 : 1.16
            grade.temperature = 0 // Do not replace the actual scene light with a preset cast.
            grade.tint = 0
            grade.contrast = evidence.brightness < 0.16 ? 1.03 : 1.08
            grade.highlights = analyzer.directorDecision.protectHighlights ? -6 : 0
            grade.shadows = analyzer.directorDecision.liftShadows ? 3 : 0
        }
        return grade
    }

    var body: some View { reviewEventsView }

    private var baseView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        Button { showingSettings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 20)).frame(width: 44, height: 44)
                        }.accessibilityLabel("拍摄设置").foregroundStyle(.white)
                            .disabled(activeRenders > 0)
                    }.padding(.horizontal, 16)
                    Spacer(minLength: 0)
                    CameraPreview(camera: camera, options: currentRenderOptions(), effectsEnabled: realtimeEffects)
                        .frame(width: min(geo.size.width, max(120, geo.size.height - (showZoomControl ? 244 : 200)) * 0.75),
                               height: min(geo.size.width / 0.75, max(160, geo.size.height - (showZoomControl ? 244 : 200))))
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { scale in
                                    if pinchStartZoom == nil { pinchStartZoom = camera.zoom }
                                    lastManualZoom = Date()
                                    camera.setZoom((pinchStartZoom ?? camera.zoom) * scale)
                                }
                                .onEnded { _ in pinchStartZoom = nil }
                        )
                        .overlay {
                            CompositionOverlay(showGrid: showGrid || autoComposition,
                                               automaticFraming: autoComposition && autoDirector,
                                               subject: analyzer.subject,
                                               composition: directorComposition,
                                               locked: analyzer.autoCaptureReady)
                        }
                        .overlay(alignment: .bottom) {
                            if autoDirector {
                                Text(analyzer.directorInstruction)
                                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                                    .padding(8).background(.black.opacity(0.55), in: Capsule())
                                    .padding(12).allowsHitTesting(false)
                            }
                        }
                    Spacer(minLength: 0)
                    controls
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(isPresentedModally: true).preferredColorScheme(.light)
        }
    }

    private var lifecycleView: some View {
        baseView
        .onAppear {
            guard self.isSelected else { return }
            self.camera.setDepthDelivery(self.portraitDepth)
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
            self.toastTask?.cancel()
        }
    }

    private var sessionEventsView: some View {
        lifecycleView
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && self.isSelected && !self.showingSettings && !self.showReview {
                self.camera.start()
                self.motion.start()
                self.location.start()
            } else {
                self.camera.stop()
                self.motion.stop()
                self.location.stop()
            }
        }
        .onChange(of: isSelected) { _, selected in
            if selected && self.scenePhase == .active && !self.showingSettings && !self.showReview {
                self.camera.start()
                self.motion.start()
                self.location.start()
            } else {
                self.camera.stop()
                self.motion.stop()
                self.location.stop()
            }
        }
        .onChange(of: showReview) { _, showing in
            if showing {
                camera.stop()
            } else if isSelected && scenePhase == .active && !showingSettings { camera.start() }
        }
        .onChange(of: showingSettings) { _, showing in
            if showing {
                camera.stop()
            } else if isSelected && scenePhase == .active { camera.start() }
        }
        .onChange(of: camera.photoToken) { _, _ in
            self.processLatestPhoto()
        }
    }

    private var reviewEventsView: some View {
        sessionEventsView
        .onChange(of: analyzer.observationTick) { _, _ in refreshDirector(); attemptAutoCapture() }
        .onChange(of: autoDirector) { _, _ in directorController.reset(); refreshDirector() }
        .onChange(of: directorFraming) { _, _ in directorController.reset(); refreshDirector() }
        .onChange(of: directorComposition) { _, _ in directorController.reset(); refreshDirector() }
        .onChange(of: autoZoom) { _, _ in directorController.reset(); refreshDirector() }
        .onChange(of: analyzer.autoCaptureReady) { _, ready in
            if !ready {
                self.autoCaptureArmed = true
                self.readySince = nil
            }
        }
        .onChange(of: location.periodText) { _, period in
            self.analyzer.setPeriod(period)
        }
        .onChange(of: autoCapture) { _, enabled in
            if !enabled {
                self.autoCaptureArmed = true
            } else if self.analyzer.autoCaptureReady {
                self.attemptAutoCapture()
            }
        }
        .onChange(of: portraitDepth) { _, enabled in camera.setDepthDelivery(enabled) }
        .onChange(of: camera.cameraPosition) { _, _ in
            sliderZoom = nil
            pinchStartZoom = nil
            directorController.reset()
            analyzer.directorObservation = DirectorObservation()
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

    // MARK: - 拍摄操作。配置与已开启状态全部留在设置页。
    private var controls: some View {
        VStack(spacing: 12) {
            if showZoomControl && camera.maximumZoom > camera.minimumZoom {
                HStack(spacing: 12) {
                    Text(String(format: "%g×", Double(camera.minimumZoom))).font(.caption2)
                    Slider(value: Binding(
                        get: { log(max(Double(camera.minimumZoom), min(Double(camera.maximumZoom), sliderZoom ?? Double(camera.zoom)))) },
                        set: { value in
                            let target = exp(value)
                            sliderZoom = target
                            lastManualZoom = Date()
                            camera.setZoom(CGFloat(target))
                        }),
                           in: log(Double(camera.minimumZoom))...log(Double(camera.maximumZoom)),
                           onEditingChanged: { editing in if !editing { sliderZoom = nil } })
                        .accessibilityLabel("连续变焦")
                        .accessibilityValue(String(format: "%.1f倍", Double(camera.zoom)))
                    Text(String(format: "%g×", Double(camera.maximumZoom))).font(.caption2)
                }.padding(.horizontal, 24)
            }
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(camera.availableZooms, id: \.self) { value in
                            Button {
                                lastManualZoom = Date()
                                camera.setZoom(value)
                            } label: {
                                Text(String(format: "%g×", Double(value)))
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(minWidth: 44, minHeight: 36)
                                    .background(abs(camera.zoom - value) < 0.08 ? Color.white.opacity(0.2) : .clear)
                                    .clipShape(Capsule())
                            }.accessibilityLabel(String(format: "变焦 %g 倍", Double(value)))
                        }
                    }
                }
                Button { showZoomControl.toggle() } label: {
                    Text(String(format: "%.1f×", Double(camera.zoom)))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 56, minHeight: 36)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }.accessibilityLabel("展开或收起连续变焦滑杆")
                    .disabled(camera.maximumZoom <= camera.minimumZoom)
            }.padding(.horizontal, 24)
            HStack {
                Color.clear.frame(width: 48, height: 48)
                Spacer()
                Button { takePhoto() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 76, height: 76)
                        Circle().fill(.white).frame(width: 64, height: 64)
                        if activeRenders > 0 { ProgressView().tint(.black) }
                    }
                }.accessibilityLabel("拍照")
                    .disabled(!camera.isRunning || activeRenders > 0)
                Spacer()
                Button { camera.switchCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 24)).frame(width: 48, height: 48)
                }.accessibilityLabel("切换前后摄像头")
            }.padding(.horizontal, 36)
        }.foregroundStyle(.white).padding(.bottom, 12)
    }

    // MARK: - 拍照结果处理（全部在后台渲染）

    private func processLatestPhoto() {
        guard camera.photoToken != lastToken else { return }
        lastToken = camera.photoToken
        guard let shot = camera.latestPhoto else { return }

        self.activeRenders += 1

        let options = captureOptions ?? currentRenderOptions()
        captureOptions = nil
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
        let metrics = shotMetrics ?? (analyzer.qualityExposure, analyzer.qualitySharpness, analyzer.compositionScore)
        UserDefaults.standard.set(metrics.0, forKey: "lastShotExposure")
        UserDefaults.standard.set(metrics.1, forKey: "lastShotSharpness")
        UserDefaults.standard.set(metrics.2, forKey: "lastShotComposition")
        UserDefaults.standard.set(Date().formatted(date: .abbreviated, time: .shortened), forKey: "lastShotDate")
        let isBest = score >= bestScore
        if isBest { self.bestScore = score }

        self.library.saveShot(originalData: shot.originalData,
                              styledImage: styled,
                              keepOriginal: keepsOriginal, photoID: shot.id) { success in
            if success {
                self.showToast("已保存到图库")
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

    private func currentRenderOptions() -> PhotoRenderOptions {
        PhotoRenderOptions(filter: effectiveFilter, grade: effectiveGrade,
                           style: compositionStyle, beauty: liveBeauty ? PortraitBeautySettings(skin: min(0.30, max(0, liveBeautyStrength)), clarity: 0, faceDepth: 0, faceSlim: 0, eyeLift: 0, environmentBlend: 0) : nil,
                           filterStrength: autoDirector && autoFilter ? min(filterStrength, analyzer.directorDecision.maximumFilterStrength) : filterStrength,
                           directorContext: autoDirector ? analyzer.directorDecision.context : nil,
                           directorEvidence: autoDirector ? analyzer.directorDecision.evidence : [])
    }

    private func takePhoto() {
        guard !showingSettings, !showReview, camera.isRunning, activeRenders == 0 else { return }
        shotMetrics = (analyzer.qualityExposure, analyzer.qualitySharpness, analyzer.compositionScore)
        captureOptions = currentRenderOptions()
        camera.capture()
    }

    private func refreshDirector() {
        guard isSelected, scenePhase == .active, camera.isRunning, !showingSettings, !showReview else { return }
        guard autoDirector else {
            camera.applyExposureCompensation(brightness: analyzer.brightness)
            return
        }
        let observation = analyzer.directorObservation
        var input = DirectorInput(observation: observation, scene: effectiveScene,
                                  sceneConfidence: autoScene ? analyzer.sceneConfidence : 1,
                                  zoom: Double(camera.zoom), minimumZoom: Double(camera.minimumZoom),
                                  maximumZoom: Double(camera.maximumZoom), nativeMaximumZoom: Double(camera.nativeMaximumZoom),
                                  stable: motion.isStable, framing: directorFraming,
                                  composition: directorComposition, preference: nil)
        input.preference = directorLearning ? DirectorPreferenceStore.shared.preference(for: DirectorEngine.context(input)) : nil
        let manualHold = Date().timeIntervalSince(lastManualZoom) <= 2
        let allow = autoZoom && autoComposition && !manualHold && activeRenders == 0
        let decision = directorController.evaluate(input, now: Date.timeIntervalSinceReferenceDate, allowAutomaticZoom: allow)
        analyzer.directorDecision = decision
        analyzer.recommendedZoom = decision.targetZoom
        analyzer.directorTitle = "AI导演 · 摄影知识决策"
        analyzer.directorInstruction = decision.summary
        analyzer.framingHint = decision.evidence.first(where: { $0.domain == "构图" })?.action ?? "等待可靠主体"
        camera.applyExposureCompensation(brightness: observation.brightness, directorBias: Float(decision.exposureBias))
        if decision.shouldZoom { camera.setZoom(CGFloat(decision.targetZoom)) }
        // Every new observation revalidates the whole shutter gate. There is no
        // fixed delay: the first frame where composition, zoom, exposure,
        // sharpness and motion are simultaneously ready fires immediately.
        if analyzer.autoCaptureReady { attemptAutoCapture() }
    }

    private func attemptAutoCapture() {
        guard !showingSettings, !showReview, isSelected, scenePhase == .active,
              autoCapture, autoCaptureArmed, analyzer.autoCaptureReady,
              pinchStartZoom == nil, sliderZoom == nil else { return }
        let manualHold = Date().timeIntervalSince(lastManualZoom) <= 2
        let zoomRatio = max(0.01, analyzer.directorDecision.targetZoom) / max(0.01, Double(camera.zoom))
        let zoomSettled = manualHold || !autoDirector || !autoZoom || abs(log(zoomRatio)) < 0.05
        guard zoomSettled, !analyzer.directorDecision.shouldZoom, analyzer.autoCaptureHeld else { readySince = nil; return }

        let shutter = SmartShutterEngine.decide(stability: motion.stabilityScore,
                                                 isStable: motion.isStable,
                                                 exposureScore: analyzer.qualityExposure,
                                                 sharpnessScore: analyzer.qualitySharpness)
        guard shutter.action == .shootNow, motion.isStable,
              analyzer.subject.rect != .zero else { readySince = nil; return }
        let box = analyzer.subject.rect
        if abs(box.midX - readyBox.midX) > 0.04 || abs(box.midY - readyBox.midY) > 0.04 || abs(box.height - readyBox.height) > 0.05 {
            readySince = nil
        }
        if readySince == nil { readySince = Date(); readyBox = box }
        // Continuous valid observations, not a scheduled shutter or countdown.
        guard Date().timeIntervalSince(readySince ?? Date()) >= 1.5 else { return }
        readySince = nil

        autoCaptureArmed = false
        takePhoto()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 子视图

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
