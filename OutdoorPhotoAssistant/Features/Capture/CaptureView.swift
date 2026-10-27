import SwiftUI
import UIKit
import CoreImage

struct CaptureView: View {
    let isSelected: Bool
    var onNavigate: (Int) -> Void = { _ in }
    @State private var autoPaused = false
    @State private var showingEffects = false
    @State private var comparingOriginal = false
    @State private var targetSelected = false
    @State private var selectedPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var exposureAdjustment = 0.0
    @State private var guidanceText = "寻找主体，点击人物指定拍摄对象"
    @State private var lastGuidanceAt = Date.distantPast
    @AppStorage("quietDirector") private var quietDirector = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var camera: CameraService
    @EnvironmentObject var motion: MotionService
    @EnvironmentObject var analyzer: FrameAnalyzer
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var library: PhotoLibraryService

    @AppStorage("showGrid") private var showGrid = true
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
    @State private var manualZoomText = "1.00"
    @AppStorage("portraitDepth") private var portraitDepth = false
    @State private var showingSettings = false
    @AppStorage("autoZoom") private var autoZoom = true
    @State private var lastManualZoom = Date.distantPast
    @AppStorage("realtimeEffects") private var realtimeEffects = true
    @AppStorage("liveBeauty") private var liveBeauty = true
    @AppStorage("liveBeautyStrength") private var liveBeautyStrength = 0.16
    @AppStorage("liveBeautyMode") private var liveBeautyModeRaw = "自然"
    private var liveBeautyMode: PortraitBeautyMode { PortraitBeautyMode(rawValue: liveBeautyModeRaw) ?? .natural }
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
    @State private var trackedBox: CGRect = .zero
    @State private var trackingSince: Date?
    @State private var trackingUpdatedAt = Date.distantPast
    @State private var subjectSpeed = 0.0
    @State private var zoomRequestedAt = Date.distantPast
    @State private var zoomStart = 1.0
    @State private var zoomPausedUntil = Date.distantPast
    @AppStorage("directorBlur") private var directorBlur = true
    @AppStorage("directorBlurStrength") private var directorBlurStrength = 0.35
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
    @State private var filterGroup: FilterGroup = .basic
    @State private var filterThumbnails: [PhotoFilter: UIImage] = [:]
    @State private var thumbnailBase: UIImage?
    @State private var thumbnailTask: Task<Void, Never>?


    private var previewAspect: CGFloat { CaptureLayout.previewAspect(frameAspect: analyzer.frameAspectRatio, landscape: false) }
    private var landscapePreviewAspect: CGFloat { CaptureLayout.previewAspect(frameAspect: analyzer.frameAspectRatio, landscape: true) }
    /// Only the camera itself may rotate; settings and review stay portrait.
    private var allowsRotation: Bool { isSelected && !showReview && !showingSettings }
    private var effectiveScene: String { autoScene ? analyzer.detectedScene : manualScene }
    private var effectiveFilter: PhotoFilter {
        guard autoFilter else { return manualFilter }
        if autoDirector { return PhotoFilter(rawValue: analyzer.directorDecision.filter) ?? .natural }
        guard !autoScene || analyzer.sceneConfidence >= 0.65 else { return .natural }
        return PhotoFilter.recommended(scene: effectiveScene, brightness: analyzer.brightness, period: location.periodText)
    }
    private var effectiveGrade: ColorGrade {
        let usesAutoGrade = autoFilter && (!autoScene || analyzer.sceneConfidence >= 0.65)
        var grade = ColorGrade.automatic(scene: effectiveScene, brightness: analyzer.brightness,
                                         period: location.periodText, confidence: autoScene ? analyzer.sceneConfidence : 1)
        if !usesAutoGrade { grade = ColorGrade() }
        if autoDirector && usesAutoGrade {
            let evidence = analyzer.directorObservation
            let measured = evidence.saturation
            let person = evidence.personCount > 0
            grade.saturation = measured > 0.48 ? 1.02 : measured < 0.12 ? 1.04 : person ? 1.08 : 1.16
            grade.temperature = 0 // Do not replace the actual scene light with a preset cast.
            grade.tint = 0
            grade.contrast = evidence.brightness < 0.16 ? 1.03 : 1.08
            grade.highlights = analyzer.directorDecision.protectHighlights ? -6 : 0
            grade.shadows = analyzer.directorDecision.liftShadows ? 3 : 0
        }
        let defaults = UserDefaults.standard
        grade.redSat += defaults.double(forKey: "spectrum_red")
        grade.orangeSat += defaults.double(forKey: "spectrum_orange")
        grade.yellowSat += defaults.double(forKey: "spectrum_yellow")
        grade.greenSat += defaults.double(forKey: "spectrum_green")
        grade.cyanSat += defaults.double(forKey: "spectrum_cyan")
        grade.blueSat += defaults.double(forKey: "spectrum_blue")
        grade.purpleSat += defaults.double(forKey: "spectrum_purple")
        return grade
    }

    // MARK: - 布局：竖屏与横屏共用同一批子视图

    private var topBar: some View {
        HStack {
            Menu {
                Button("图库") { onNavigate(1) }
                Button("摄影学院") { onNavigate(2) }
                Button("全部设置") { onNavigate(3) }
            } label: { Image(systemName: "square.grid.2x2").frame(width: 44, height: 44) }
            Button { camera.requestedFlash.toggle() } label: {
                Image(systemName: camera.requestedFlash ? "bolt.fill" : "bolt.slash").frame(width: 44, height: 44)
            }.accessibilityLabel("拍照闪光灯").disabled(!camera.flashAvailable)
            Spacer()
            Button { camera.switchCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 44, height: 44) }

            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20)).frame(width: 44, height: 44)
            }.accessibilityLabel("拍摄设置").foregroundStyle(.white)
                .disabled(activeRenders > 0)
        }.padding(.horizontal, 16)
    }

    private func previewView(width: CGFloat, height: CGFloat) -> some View {
        CameraPreview(camera: camera, options: currentRenderOptions(), effectsEnabled: !comparingOriginal && (realtimeEffects || liveBeauty || effectiveFilter != .natural || (directorBlur && autoDirector)),
                      autoFocusPoint: autoDirector && !camera.focusExposureLocked && Date().timeIntervalSince(analyzer.visionEvidenceAt) < 0.8 ? (targetSelected && analyzer.subject.rect != .zero ? CGPoint(x: analyzer.subject.rect.midX, y: analyzer.subject.rect.midY) : analyzer.visionEvidence.focusPoint) : nil,
                      focusObservationTick: analyzer.observationTick,
                      onSubjectTap: { point, locked in
                          targetSelected = true; selectedPoint = point; analyzer.selectSubject(at: point)
                          camera.setFocusExposureLock(locked)
                          readySince = nil
                      })
            .frame(width: width, height: height)
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        if pinchStartZoom == nil { pinchStartZoom = camera.zoom }
                        lastManualZoom = Date()
                        autoZoom = false
                        camera.setZoom((pinchStartZoom ?? camera.zoom) * scale)
                    }
                    .onEnded { _ in pinchStartZoom = nil }
            )
            .overlay {
                CompositionOverlay(showGrid: showGrid,
                                   automaticFraming: autoComposition && autoDirector,
                                   subject: analyzer.subject,
                                   composition: directorComposition,
                                   locked: analyzer.autoCaptureReady && camera.controlsSettled && analyzer.visionEvidence.eyes != "closed")
            }
            .overlay {
                GeometryReader { proxy in
                    if targetSelected {
                        HStack(spacing: 4) {
                            Image(systemName: "sun.max.fill")
                            Slider(value: $exposureAdjustment, in: -2...2)
                                .frame(width: 95)
                                .onChange(of: exposureAdjustment) { _, value in camera.setUserExposure(Float(value)); readySince = nil }
                        }.foregroundStyle(.yellow)
                            .frame(width: 120)
                            .position(x: max(70, min(proxy.size.width - 70, selectedPoint.x * proxy.size.width)),
                                      y: max(35, min(proxy.size.height - 70, (1 - selectedPoint.y) * proxy.size.height + 45)))
                    }
                    if abs(analyzer.horizonAngle) > 0.03 && autoComposition {
                        Capsule().fill(.white.opacity(0.65)).frame(width: 70, height: 2)
                            .rotationEffect(.radians(-analyzer.horizonAngle))
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            .allowsHitTesting(false)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if autoDirector && !quietDirector {
                    HStack(spacing: 6) {
                        if guidanceText.contains("向左") { Image(systemName: "arrow.left") }
                        else if guidanceText.contains("向右") { Image(systemName: "arrow.right") }
                        else if guidanceText.contains("后退") { Image(systemName: "arrow.down") }
                        Text(guidanceText)
                    }
                        .font(.caption.weight(.medium)).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.55), in: Capsule())
                        .padding(12).allowsHitTesting(false)
                }
            }
    }

    private var intentPicker: some View {
        Picker("拍摄意图", selection: $directorFraming) {
            ForEach(["自动", "环境", "完整人物", "半身", "特写", "合影", "运动", "突出主体"], id: \.self) { Text($0).tag($0) }
        }.tint(.white)
    }

    /// Keep the choice visible while framing; the sheet remains for beauty and advanced controls.
    private func inlineFilters(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("滤镜", systemImage: "camera.filters")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Menu {
                    ForEach(FilterGroup.allCases) { group in
                        Button(group.rawValue) { filterGroup = group }
                    }
                } label: {
                    Label(filterGroup.rawValue, systemImage: "chevron.down")
                        .font(.caption)
                }
                Button("更多效果") { autoPaused = true; showingEffects = true }
                    .font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChoice("自动", icon: "sparkles", selected: autoFilter) {
                        autoFilter = true; readySince = nil
                    }
                    ForEach(PhotoFilter.filters(in: filterGroup)) { filter in
                        filterChoice(filter.rawValue, icon: filter.icon,
                                     selected: !autoFilter && manualFilter == filter) {
                            autoFilter = false
                            manualFilterName = filter.rawValue
                            readySince = nil
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, 8)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, compact ? 0 : 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("拍照滤镜")
    }

    private func filterChoice(_ title: String, icon: String, selected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(minWidth: 54, minHeight: 42)
            .padding(.horizontal, 5)
            .background(selected ? Color.mint.opacity(0.36) : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.mint : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func intentRow(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                intentPicker
                HStack {
                    Spacer()
                    Button(quietDirector ? "显示引导" : "安静") { quietDirector.toggle() }
                }
            }.font(.caption).foregroundStyle(.white).padding(.horizontal, 4)
        } else {
            HStack {
                intentPicker
                Spacer()
                Button(quietDirector ? "显示引导" : "安静") { quietDirector.toggle() }
            }.font(.caption).foregroundStyle(.white).padding(.horizontal, 20)
        }
    }

    @ViewBuilder private func selectedRow(compact: Bool) -> some View {
        if compact && targetSelected {
            VStack(spacing: 6) {
                HStack {
                    Text(camera.focusExposureLocked ? "主体与AE/AF锁定" : "已选择主体")
                    Spacer()
                    Button("恢复自动") { targetSelected = false; analyzer.selectSubject(at: nil); camera.setFocusExposureLock(false); camera.setUserExposure(nil); exposureAdjustment = 0; lastManualZoom = .distantPast }
                }
                HStack {
                    Image(systemName: "sun.max")
                    Slider(value: $exposureAdjustment, in: -2...2).onChange(of: exposureAdjustment) { _, value in camera.setUserExposure(Float(value)); readySince = nil }
                }
            }.font(.caption).foregroundStyle(.white).padding(.horizontal, 4)
        } else {
            if targetSelected {
                HStack {
                    Text(camera.focusExposureLocked ? "主体与AE/AF锁定" : "已选择主体")
                    Button("恢复自动") { targetSelected = false; analyzer.selectSubject(at: nil); camera.setFocusExposureLock(false); camera.setUserExposure(nil); exposureAdjustment = 0; lastManualZoom = .distantPast }
                    Image(systemName: "sun.max")
                    Slider(value: $exposureAdjustment, in: -2...2).onChange(of: exposureAdjustment) { _, value in camera.setUserExposure(Float(value)); readySince = nil }
                }.font(.caption).foregroundStyle(.white).padding(.horizontal, 20)
        }
        }
    }

    private func portraitLayout(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            topBar
            Spacer(minLength: 0)
            previewView(width: min(geo.size.width, max(120, geo.size.height - (showZoomControl ? 330 : 286)) * previewAspect),
                        height: min(geo.size.width / previewAspect, max(160, geo.size.height - (showZoomControl ? 330 : 286))))
            Spacer(minLength: 0)
            inlineFilters(compact: false)
            intentRow(compact: false)
            selectedRow(compact: false)
            controls(compact: false)
                .padding(.bottom, 120) // Reserved for the independent shutter dock and system tab bar.
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Landscape: viewfinder on the left, one scrollable control column on the right.
    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        let sideWidth: CGFloat = 236
        let available = CGSize(width: max(200, geo.size.width - sideWidth - 28),
                               height: max(120, geo.size.height - 56))
        let size = CaptureLayout.fit(aspect: landscapePreviewAspect, in: available)
        return HStack(spacing: 12) {
            VStack(spacing: 8) {
                topBar
                Spacer(minLength: 0)
                previewView(width: size.width, height: size.height)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    inlineFilters(compact: true)
                    intentRow(compact: true)
                    selectedRow(compact: true)
                    controls(compact: true)
                }
            }.frame(width: sideWidth)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 8)
    }

    private var captureBase: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                if CaptureLayout.isLandscape(geo.size) { landscapeLayout(geo) } else { portraitLayout(geo) }
            }
            GeometryReader { geo in
                if !CaptureLayout.isLandscape(geo.size) {
                    VStack {
                        Spacer(minLength: 0)
                        fixedPortraitShutterDock
                            .padding(.bottom, 86) // Keep clear of the system TabView bar.
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
        .sheet(isPresented: $showingEffects) { effectsPanel }
        .onChange(of: allowsRotation, initial: true) { _, allowed in
            OrientationPolicy.apply(allowed ? .allButUpsideDown : .portrait)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(isPresentedModally: true).preferredColorScheme(.light)
        }
    }

    private var captureLifecycle: some View {
        captureBase
        .onAppear {
            guard self.isSelected else { return }
            OrientationPolicy.apply(allowsRotation ? .allButUpsideDown : .portrait)
            self.camera.setDepthDelivery(self.portraitDepth)
            self.camera.setHighQualityMode(self.highQuality)
            self.camera.start()
            self.motion.start()
            self.location.start()
            self.analyzer.setPeriod(self.location.periodText)
        }
        .onDisappear {
            OrientationPolicy.apply(.portrait)
            comparingOriginal = false
            self.camera.stop()
            self.motion.stop()
            self.location.stop()
            self.toastTask?.cancel()
        }
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
    }

    var body: some View {
        captureLifecycle
        .onChange(of: camera.photoToken) { _, _ in
            self.processLatestPhoto()
        }
        .onChange(of: analyzer.observationTick) { _, _ in
            refreshDirector(); attemptAutoCapture()
            if Date().timeIntervalSince(lastGuidanceAt) > 1 {
                guidanceText = waitingReason
                lastGuidanceAt = Date()
            }
        }
        .onChange(of: analyzer.autoCaptureReady) { _, ready in
            if ready && quietDirector { UISelectionFeedbackGenerator().selectionChanged() }
        }
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
            targetSelected = false; analyzer.selectSubject(at: nil); camera.setFocusExposureLock(false)
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

    private var waitingReason: String {
        if targetSelected && analyzer.subject.rect == .zero { return "选中主体已离开，请重新点击或恢复自动" }
        if analyzer.brightness < 0.16 { return "光线不足，请靠近光源或稳住手机" }
        if camera.zoom > camera.nativeMaximumZoom * 1.5 { return "高倍率细节可能下降，可拉近拍摄距离或手动降低倍率" }
        if !camera.controlsSettled { return "正在对焦、测光或变焦，请稍候" }
        if autoPaused { return "自动拍摄已暂停，可手动拍照" }
        if analyzer.directorObservation.personCount > 0 && analyzer.visionEvidence.eyes == "unknown" { return "眼部无法确认，可调整角度或手动拍摄" }
        if analyzer.visionEvidence.eyes == "closed" { return "疑似闭眼，等待合适时机" }
        if !motion.isStable { return "请稳住手机" }
        return analyzer.directorInstruction
    }
    private var effectsPanel: some View {
        NavigationStack {
            Form {
                Section("滤镜 · 点击实时预览") {
                    Toggle("自动匹配", isOn: $autoFilter)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(FilterGroup.allCases) { group in
                                Button { filterGroup = group } label: {
                                    Text(group.rawValue)
                                        .font(.subheadline.weight(filterGroup == group ? .semibold : .regular))
                                        .foregroundStyle(filterGroup == group ? .white : .secondary)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(filterGroup == group ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical, 2)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(PhotoFilter.filters(in: filterGroup)) { filter in
                                Button { autoFilter = false; manualFilterName = filter.rawValue } label: {
                                    VStack {
                                        if let image = filterThumbnails[filter] {
                                            Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                        } else {
                                            RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)).frame(width: 64, height: 80).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                                        }
                                        Text(filter.rawValue).font(.caption)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .task(id: filterGroup) { await refreshThumbnails() }
                    Slider(value: $filterStrength, in: 0...1) { Text("滤镜强度") }
                }
                Section("人像") {
                    Toggle("实时美颜", isOn: $liveBeauty)
                    if liveBeauty {
                        Picker("模式", selection: $liveBeautyModeRaw) {
                            ForEach(PortraitBeautyMode.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                        }.pickerStyle(.segmented).frame(width: 140)
                        let ceiling = liveBeautyMode == .advanced ? 1.0 : 0.30
                        Slider(value: $liveBeautyStrength, in: 0...ceiling) { Text("美颜度") }
                        Text("单一美颜度控制磨皮、美白、提亮、瘦脸等全部参数。自然模式封顶30%。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("单人突出主体轻虚化", isOn: $directorBlur)
                    Slider(value: $directorBlurStrength, in: 0...0.65) { Text("虚化强度") }
                }
                Section {
                    Text("按住下方按钮看效果前预览；松开恢复。这里不是RAW。")
                    Text("自动拍摄暂时暂停，关闭面板后可用快门旁按钮恢复。")
                }
            }.navigationTitle("拍摄效果")
                .toolbar { Button("完成") { showingEffects = false } }
                .onAppear { filterThumbnails.removeAll() }
        }
        .presentationDetents([.medium, .large])
    }
    private func refreshThumbnails() async {
        thumbnailTask?.cancel()
        let base = camera.previewThumbnail
        guard let cg = base?.cgImage else { return }
        let group = filterGroup
        let filters = PhotoFilter.filters(in: group)
        let cached = filterThumbnails
        let toGenerate = filters.filter { cached[$0] == nil }
        guard !toGenerate.isEmpty else { return }
        let input = CIImage(cgImage: cg)
        let scale = min(1, 120 / max(input.extent.width, input.extent.height))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let result = await Task.detached(priority: .userInitiated) {
            var generated: [PhotoFilter: UIImage] = [:]
            for filter in toGenerate {
                if Task.isCancelled { break }
                let output = PhotoFilterEngine.apply(filter, to: small)
                if let cgOut = ImagePipeline.context.createCGImage(output, from: output.extent) {
                    generated[filter] = UIImage(cgImage: cgOut)
                }
            }
            return generated
        }.value
        if !Task.isCancelled { filterThumbnails.merge(result) { _, new in new } }
    }

    // MARK: - 拍摄操作。配置与已开启状态全部留在设置页。
    private func controls(compact: Bool) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("变焦模式").font(.caption)
                Picker("变焦模式", selection: $autoZoom) {
                    Text("手动").tag(false)
                    Text("自动").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: autoZoom) { _, enabled in
                    if enabled { lastManualZoom = .distantPast; directorController.reset() }
                    else { lastManualZoom = Date(); manualZoomText = String(format: "%.2f", Double(camera.zoom)) }
                }
            }.padding(.horizontal, compact ? 6 : 24)
            if !autoZoom && camera.maximumZoom > camera.minimumZoom {
                HStack(spacing: 12) {
                    Text(String(format: "%g×", Double(camera.minimumZoom))).font(.caption2)
                    Slider(value: Binding(
                        get: { log(max(Double(camera.minimumZoom), min(Double(camera.maximumZoom), sliderZoom ?? Double(camera.zoom)))) },
                        set: { value in
                            let target = min(100, max(Double(camera.minimumZoom), min(Double(camera.maximumZoom), (exp(value) * 100).rounded() / 100)))
                            sliderZoom = target
                            manualZoomText = String(format: "%.2f", target)
                            lastManualZoom = Date()
                            camera.setZoom(CGFloat(target))
                        }),
                           in: log(Double(camera.minimumZoom))...log(Double(camera.maximumZoom)),
                           onEditingChanged: { editing in if !editing { sliderZoom = nil } })
                        .accessibilityLabel("连续变焦")
                        .accessibilityValue(String(format: "%.2f倍", Double(camera.zoom)))
                    Text(String(format: "%g×", Double(camera.maximumZoom))).font(.caption2)
                }.padding(.horizontal, compact ? 6 : 24)
                HStack(spacing: 10) {
                    Text("倍率").font(.caption)
                    TextField("1.00", text: $manualZoomText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("输入手动变焦倍率，精确到0.01倍")
                    Button("应用") {
                        guard let entered = Double(manualZoomText), entered.isFinite else { return }
                        let target = min(100, max(Double(camera.minimumZoom), min(Double(camera.maximumZoom), (entered * 100).rounded() / 100)))
                        manualZoomText = String(format: "%.2f", target)
                        lastManualZoom = Date()
                        camera.setZoom(CGFloat(target))
                    }
                    .buttonStyle(.bordered)
                    Text("上限 " + String(format: "%.2f×", min(100, Double(camera.maximumZoom))))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, compact ? 6 : 24)
            }
            HStack {
                Text("效果前预览").font(.caption).padding(8).background(.white.opacity(0.12), in: Capsule())
                    .onLongPressGesture(minimumDuration: 0, pressing: { pressing in comparingOriginal = pressing; if pressing { readySince = nil } }, perform: {})
                    .accessibilityLabel("按住查看效果前预览")
                if lastManualZoom != .distantPast {
                    Button("恢复自动变焦") { autoZoom = true; lastManualZoom = .distantPast; directorController.reset() }
                }
            }
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(camera.availableZooms.filter { $0 <= max(2, camera.nativeMaximumZoom) }, id: \.self) { value in
                            Button {
                                autoZoom = false
                                lastManualZoom = Date()
                                manualZoomText = String(format: "%.2f", Double(value))
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
                    Text(String(format: "%.2f×", Double(camera.zoom)))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 56, minHeight: 36)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }.accessibilityLabel("显示或隐藏变焦控制")
                    .disabled(camera.maximumZoom <= camera.minimumZoom)
            }.padding(.horizontal, compact ? 6 : 24)
            if compact {
            HStack {
                Button {
                    if let shot = reviewShot, reviewStyled != nil { reviewShot = shot; showReview = true }
                    else { onNavigate(1) }
                } label: {
                    if let image = reviewStyled { Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 9)) }
                    else { Image(systemName: "photo").frame(width: 48, height: 48) }
                }.accessibilityLabel("最近照片与图库")
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
                Button { if !autoCapture { autoCapture = true; autoPaused = false } else { autoPaused.toggle() }; readySince = nil } label: {
                    Image(systemName: autoPaused || !autoCapture ? "play.circle" : "pause.circle")
                        .font(.system(size: 28)).frame(width: 48, height: 48)
                }.accessibilityLabel(autoPaused ? "恢复自动拍摄" : "暂停自动拍摄")
            }.padding(.horizontal, compact ? 10 : 36)
            }
        }.foregroundStyle(.white).padding(.bottom, 12)
    }


    /// Portrait shutter is anchored above the system tab bar and never scrolls with zoom controls.
    private var fixedPortraitShutterDock: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    if let shot = reviewShot, reviewStyled != nil { reviewShot = shot; showReview = true }
                    else { onNavigate(1) }
                } label: {
                    if let image = reviewStyled { Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 9)) }
                    else { Image(systemName: "photo").frame(width: 48, height: 48) }
                }.accessibilityLabel("最近照片与图库")
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
                Button { if !autoCapture { autoCapture = true; autoPaused = false } else { autoPaused.toggle() }; readySince = nil } label: {
                    Image(systemName: autoPaused || !autoCapture ? "play.circle" : "pause.circle")
                        .font(.system(size: 28)).frame(width: 48, height: 48)
                }.accessibilityLabel(autoPaused ? "恢复自动拍摄" : "暂停自动拍摄")
            }.padding(.horizontal, 36)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 22)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 拍照结果处理（全部在后台渲染）

    private func processLatestPhoto() {
        guard camera.photoToken != lastToken else { return }
        lastToken = camera.photoToken
        guard let shot = camera.latestPhoto else { return }

        self.activeRenders += 1

        var preparedOptions = captureOptions ?? currentRenderOptions()
        captureOptions = nil
        let exposure = analyzer.qualityExposure
        let composition = analyzer.compositionScore
        let sharpness = analyzer.qualitySharpness
        let keepsOriginal = saveBoth
        let depthStrength = min(1, max(0, directorBlurStrength))
        let useMatteDepth = shot.depthMask != nil && preparedOptions.directorEvidence.contains { $0.domain == "自动景深" }
        if useMatteDepth { preparedOptions.backgroundBlur = 0 }
        let options = preparedOptions

        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = PhotoPostProcessor.render(original: shot.image, options: options)
            let styled = rendered.flatMap { image in
                useMatteDepth ? DepthPortraitProcessor.apply(image: image, mask: shot.depthMask, strength: depthStrength) : image
            }
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
                            options: options,
                            keepsOriginal: keepsOriginal)
            }
        }
    }

    private func finish(shot: CapturedPhoto,
                        styled: UIImage,
                        score: Int,
                        options: PhotoRenderOptions,
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

        self.reviewShot = shot
        self.reviewStyled = styled
        self.reviewOptions = options
        self.reviewIsBest = isBest
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
                           style: compositionStyle, beauty: liveBeauty ? BeautyPreset(intensity: liveBeautyStrength).settings(mode: liveBeautyMode) : nil,
                           outputAspect: Double(previewAspect),
                           filterStrength: autoDirector && autoFilter ? min(filterStrength, analyzer.directorDecision.maximumFilterStrength) : filterStrength,
                           backgroundBlur: directorBlur && autoDirector && analyzer.directorObservation.personCount == 1 && ["半身", "特写", "突出主体"].contains(directorFraming) ? directorBlurStrength : 0,
                           directorContext: autoDirector ? analyzer.directorDecision.context : nil,
                           directorEvidence: autoDirector ? analyzer.directorDecision.evidence : [])
    }

    private func takePhoto() {
        guard !showingSettings, !showReview, camera.isRunning, activeRenders == 0 else { return }
        shotMetrics = (analyzer.qualityExposure, analyzer.qualitySharpness, analyzer.compositionScore)
        var options = currentRenderOptions()
        if autoDirector && portraitDepth && analyzer.directorObservation.personCount == 1 && ["半身", "特写", "突出主体"].contains(directorFraming) {
            options.directorEvidence.append(DirectorEvidence(domain: "自动景深", rule: "单人突出主体", observation: "请求轻度背景分离", action: "仅当成片存在人物遮罩时轻度虚化；缺少遮罩时保留原景"))
        }
        options.directorEvidence.append(DirectorEvidence(domain: "设备执行", rule: "实际控制状态", observation: camera.exposureText + String(format: " · %.2f×", Double(camera.zoom)), action: camera.controlsSettled ? "系统对焦、曝光与变焦已稳定" : "本次为手动快门或控制尚未稳定"))
        captureOptions = options
        camera.capture()
    }

    private func refreshDirector() {
        guard isSelected, scenePhase == .active, camera.isRunning, !showingSettings, !showReview else { return }
        camera.applyMotionExposure(enabled: autoDirector && directorFraming == "运动")
        guard autoDirector else {
            camera.applyExposureCompensation(brightness: analyzer.brightness)
            return
        }
        let box = analyzer.subject.rect
        let now = Date()
        let intersection = box.intersection(trackedBox)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let unionArea = box.width * box.height + trackedBox.width * trackedBox.height - intersectionArea
        if box == .zero || now.timeIntervalSince(trackingUpdatedAt) > 0.8 || intersectionArea / max(0.00001, unionArea) < 0.35 {
            trackingSince = box == .zero ? nil : now
            readySince = nil
        }
        let dt = now.timeIntervalSince(trackingUpdatedAt)
        subjectSpeed = dt > 0.05 && dt < 0.8 && trackedBox != .zero ? Double(hypot(box.midX - trackedBox.midX, box.midY - trackedBox.midY)) / dt : 0
        trackedBox = box; trackingUpdatedAt = now
        let observation = analyzer.directorObservation
        var input = DirectorInput(observation: observation, scene: effectiveScene,
                                  sceneConfidence: autoScene ? analyzer.sceneConfidence : 1,
                                  zoom: Double(camera.zoom), minimumZoom: Double(camera.minimumZoom),
                                  maximumZoom: Double(camera.maximumZoom), nativeMaximumZoom: Double(camera.nativeMaximumZoom),
                                  stable: motion.isStable, framing: directorFraming,
                                  composition: directorComposition, preference: nil)
        input.preference = directorLearning ? DirectorPreferenceStore.shared.preference(for: DirectorEngine.context(input)) : nil
        let manualHold = lastManualZoom != .distantPast
        if Date().timeIntervalSince(zoomRequestedAt) > 2 && Date().timeIntervalSince(zoomRequestedAt) < 3 && abs(Double(camera.zoom) - zoomStart) < 0.02 {
            zoomPausedUntil = Date().addingTimeInterval(8)
        }
        let allow = autoZoom && autoComposition && !manualHold && activeRenders == 0 && Date() > zoomPausedUntil
        let decision = directorController.evaluate(input, now: Date.timeIntervalSinceReferenceDate, allowAutomaticZoom: allow)
        analyzer.directorDecision = decision
        analyzer.recommendedZoom = decision.targetZoom
        analyzer.directorTitle = "AI导演 · 摄影知识决策"
        analyzer.directorInstruction = decision.summary
        analyzer.framingHint = decision.evidence.first(where: { $0.domain == "构图" })?.action ?? "等待可靠主体"
        camera.applyExposureCompensation(brightness: observation.brightness, directorBias: Float(decision.exposureBias))
        if decision.shouldZoom {
            zoomRequestedAt = Date(); zoomStart = Double(camera.zoom)
            camera.setZoom(CGFloat(decision.targetZoom))
        }
        if Date() < zoomPausedUntil { analyzer.directorInstruction = "镜头未响应变焦，已暂停重试；请移动机位或手动选倍率" }
        else if Date().timeIntervalSince(analyzer.visionEvidenceAt) < 0.8 {
            if analyzer.visionEvidence.eyes == "closed" { analyzer.directorInstruction = "检测到可能闭眼，等待睁眼后再拍" }
            else if !analyzer.visionEvidence.poseHint.isEmpty { analyzer.directorInstruction = analyzer.visionEvidence.poseHint }
        }
        // Every new observation revalidates the whole shutter gate. There is no
        // fixed delay: the first frame where composition, zoom, exposure,
        // sharpness and motion are simultaneously ready fires immediately.
        if analyzer.autoCaptureReady { attemptAutoCapture() }
    }

    private func attemptAutoCapture() {
        guard !showingSettings, !showReview, isSelected, scenePhase == .active,
              autoCapture, !autoPaused, !showingEffects, !comparingOriginal, autoCaptureArmed, analyzer.autoCaptureReady,
              pinchStartZoom == nil, sliderZoom == nil else { return }
        guard
              Date().timeIntervalSince(trackingUpdatedAt) < 0.8,
              Date().timeIntervalSince(trackingSince ?? Date()) > 1,
              camera.controlsSettled,
              Date().timeIntervalSince(camera.controlsUpdatedAt) < 0.8 else { readySince = nil; return }
        let manualHold = lastManualZoom != .distantPast
        let zoomRatio = max(0.01, analyzer.directorDecision.targetZoom) / max(0.01, Double(camera.zoom))
        let zoomSettled = manualHold || !autoDirector || !autoZoom || abs(log(zoomRatio)) < 0.05
        guard zoomSettled, !analyzer.directorDecision.shouldZoom, analyzer.autoCaptureHeld else { readySince = nil; return }

        let hasPeople = analyzer.directorObservation.personCount > 0
        if hasPeople {
            guard Date().timeIntervalSince(analyzer.visionEvidenceAt) < 0.8,
                  analyzer.visionEvidence.eyes == "open" else { readySince = nil; return }
        }
        let motionExposure = directorFraming == "运动" ? 1.0 / 500 : 1.0 / 125
        guard camera.exposureSeconds <= motionExposure,
              subjectSpeed * camera.exposureSeconds < 0.0015 else { readySince = nil; return }
        let shutter = SmartShutterEngine.decide(stability: motion.stabilityScore,
                                                 isStable: motion.isStable,
                                                 exposureScore: analyzer.qualityExposure,
                                                 sharpnessScore: analyzer.qualitySharpness)
        guard shutter.action == .shootNow, motion.isStable,
              analyzer.subject.rect != .zero else { readySince = nil; return }
        let box = analyzer.subject.rect
        if directorFraming != "运动" && (abs(box.midX - readyBox.midX) > 0.04 || abs(box.midY - readyBox.midY) > 0.04 || abs(box.height - readyBox.height) > 0.05) {
            readySince = nil
        }
        if readySince == nil { readySince = Date(); readyBox = box }
        // Continuous valid observations, not a scheduled shutter or countdown.
        guard Date().timeIntervalSince(readySince ?? Date()) >= (directorFraming == "运动" ? 0.4 : 1.5) else { return }
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
