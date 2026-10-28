import AVFoundation
import SwiftUI
import UIKit

/// 一次拍摄产生的数据。原片保留原始字节（EXIF/深度都在里面），另附解码后的图用于后处理。
struct CapturedPhoto {
    let id = UUID()
    let originalData: Data
    let image: UIImage
    let depthPortrait: UIImage?
    let depthMask: UIImage?
    let capturedAt: Date

    /// Display dimensions after applying the photo's EXIF orientation.  The raw
    /// sensor pixels may still be stored portrait-first, so `cgImage.width` alone
    /// cannot decide whether this was a horizontal photo.
    var displayPixelSize: CGSize {
        let raw = image.cgImage.map {
            CGSize(width: CGFloat($0.width), height: CGFloat($0.height))
        } ?? image.size
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: raw.height, height: raw.width)
        default:
            return raw
        }
    }

    var displayAspect: CGFloat {
        let size = displayPixelSize
        guard size.width > 0, size.height > 0 else { return 1 }
        return size.width / size.height
    }

    var isLandscape: Bool { displayAspect > 1 }
}

/// 相机服务。
///
/// 与上一版的关键差异：
/// - 打开输出级 depth/portrait-effects-matte 开关（否则拍照会抛异常），并修掉相关编译错误；
/// - 所有可变光圈 / Camera Control / ProRAW 等新系统 API 全部移除，保证在 iOS 17.6+ 与 iOS 26 SDK 下都能编译；
/// - 拍照期间不重配 session，避免丢快门；
/// - 曝光只做曝光补偿（带死区 + 速率限制），不再和系统 AE 抢控制权；
/// - 变焦用单一后置虚拟设备 + 仅在 0.5× 时切换超广角物理设备。
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let realtimePreview = RealtimePreviewProcessor()

    private let sessionQueue = DispatchQueue(label: "opa.camera.session")
    private let videoQueue = DispatchQueue(label: "opa.camera.video")
    private let photoQueue = DispatchQueue(label: "opa.camera.photo", qos: .userInitiated)

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let engine = AdaptiveCameraEngine()
    private let stateLock = NSLock()

    private var zoomRangeObservations: [NSKeyValueObservation] = []
    private var requestedDepthDelivery = false
    private var depthConfigurationPending = false
    private var zoomObservation: NSKeyValueObservation?
    private var input: AVCaptureDeviceInput?
    private(set) var currentDevice: AVCaptureDevice?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var isConfiguring = false
    private var wantsRunning = false // Access only on sessionQueue.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator? // Access only on sessionQueue.
    private var rotationObservation: NSKeyValueObservation?
    private var lastStableRotationAngle: CGFloat = 90 // Access only on sessionQueue.
    private var requestedHighQuality = true
    private var directorOwnsExposure = false
    private var lastMotionExposureUpdate = Date.distantPast
    private var captureInFlight = 0
    private var pendingUserZoom: CGFloat?
    private var lastBias: Float = 0
    private var lastBiasTime: CFAbsoluteTime = 0
    private var observers: [NSObjectProtocol] = []

    var onFrame: ((CMSampleBuffer, AVCaptureDevice.Position) -> Void)?

    @Published var isRunning = false
    @Published var authorizationDenied = false
    @Published var errorMessage: String?
    @Published var zoom: CGFloat = 1
    @Published var requestedFlash = false
    @Published private(set) var flashAvailable = false
    @Published private(set) var previewThumbnail: UIImage?
    private var lastThumbnailTime = 0.0
    private let thumbnailQueue = DispatchQueue(label: "opa.preview.thumbnail", qos: .utility)
    private var thumbnailBusy = false
    @Published private(set) var manualExposure = false
    @Published private(set) var focusExposureLocked = false
    private var userBias: Float = 0
    @Published var availableZooms: [CGFloat] = [1]
    @Published private(set) var nativeMaximumZoom: CGFloat = 1
    @Published private(set) var minimumZoom: CGFloat = 1
    @Published private(set) var maximumZoom: CGFloat = 1
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var exposureText = "EV 0.0"
    @Published private(set) var exposureSeconds = 1.0
    @Published private(set) var controlsSettled = false
    @Published private(set) var controlsUpdatedAt = Date.distantPast
    @Published var apertureText = "f/1.8"
    @Published var depthSupported = false
    @Published var portraitMatteSupported = false
    @Published private(set) var highQualityMode = true
    @Published var cameraEngineSummary = "均衡·画质优先"
    @Published var cameraEngineTier = "均衡"
    @Published var lowLightBoostActive = false
    @Published var hardwareHDRActive = false
    @Published var latestPhoto: CapturedPhoto?
    @Published var photoToken = UUID()
    /// Rotation (degrees) that makes the preview, analysis frames and photos upright for the way the
    /// phone is held right now. 90 = portrait on the rear camera, 0 / 180 = the two landscapes.
    @Published private(set) var previewRotationAngle: CGFloat = 90
    @Published private(set) var orientationLabel = "竖拍 3:4"

    var isLandscapeCapture: Bool {
        CaptureLayout.isLandscape(rotationAngle: previewRotationAngle)
    }

    override init() {
        super.init()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        installObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        zoomRangeObservations.forEach { $0.invalidate() }
        zoomRangeObservations.removeAll()
        zoomObservation?.invalidate()
        rotationObservation?.invalidate()
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
    }

    // MARK: - 生命周期与恢复

    private func installObservers() {
        let center = NotificationCenter.default
        let session = self.session

        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: session,
                                            queue: .main) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self.errorMessage = error?.localizedDescription ?? "相机运行时发生错误"
            if error?.code == AVError.mediaServicesWereReset.rawValue {
                self.restartIfAuthorized()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                            object: session,
                                            queue: .main) { [weak self] _ in
            self?.errorMessage = "相机被系统暂时中断"
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session,
                                            queue: .main) { [weak self] _ in
            self?.errorMessage = nil
            self?.restartIfAuthorized()
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                guard let device = self.currentDevice else { return }
                self.engine.refreshProfile()
                self.engine.configure(device)
                self.publishHardwareState(device)
            }
        })
    }

    private func restartIfAuthorized() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.wantsRunning, !self.isConfiguring else { return }
            self.session.stopRunning()
            self.session.startRunning()
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    func start() {
        sessionQueue.async { self.wantsRunning = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.authorizationDenied = false }
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async { self.authorizationDenied = !granted }
                if granted { self.configureAndStart() }
            }
        default:
            DispatchQueue.main.async { self.authorizationDenied = true }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.wantsRunning, !self.session.isRunning, !self.isConfiguring else { return }
            self.isConfiguring = true
            self.session.beginConfiguration()

            if self.session.canSetSessionPreset(.photo) {
                self.session.sessionPreset = .photo
            } else if self.session.canSetSessionPreset(.high) {
                self.session.sessionPreset = .high
            }

            self.removeCurrentInput()
            guard self.installCamera(position: self.currentPosition, userZoom: self.zoom) else {
                self.session.commitConfiguration()
                self.isConfiguring = false
                self.publishError("找不到可用的摄像头")
                return
            }

            if !self.session.outputs.contains(self.photoOutput) {
                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    self.isConfiguring = false
                    self.publishError("当前设备无法建立照片输出")
                    return
                }
                self.session.addOutput(self.photoOutput)
            }
            if !self.session.outputs.contains(self.videoOutput), self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            self.photoOutput.maxPhotoQualityPrioritization = .quality
            self.configureAdvancedCaptureSupport()
            self.configureConnections()

            self.session.commitConfiguration()
            self.isConfiguring = false
            self.session.startRunning()
            self.updateZoomOptions()
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    /// 必须在 startRunning 之前配置：Apple 文档要求输出级开关先打开，
    /// 之后照片请求里才能带 depth / portrait effects matte。
    private func configureAdvancedCaptureSupport() {
        if let dimensions = currentDevice?.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) {
            photoOutput.maxPhotoDimensions = dimensions
        }
        if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
        }
        if photoOutput.isDepthDataDeliveryEnabled {
            photoOutput.isDepthDataDeliveryEnabled = false
        }
        let depth = requestedDepthDelivery && photoOutput.isDepthDataDeliverySupported
        if depth {
            photoOutput.isDepthDataDeliveryEnabled = true
        }
        let matte = depth && photoOutput.isPortraitEffectsMatteDeliverySupported
        if matte {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
        }
        if photoOutput.isContentAwareDistortionCorrectionSupported {
            photoOutput.isContentAwareDistortionCorrectionEnabled = true
        }
        DispatchQueue.main.async {
            self.depthSupported = depth
            self.portraitMatteSupported = matte
        }
    }

    /// Follows the physical orientation of the phone, so portrait and landscape shots are both upright.
    /// `videoRotationAngleForHorizonLevelCapture` also accounts for the front camera.
    private var currentRotationAngle: CGFloat {
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture {
            return CaptureLayout.normalizedRotationAngle(angle)
        }
        // RotationCoordinator is available on the deployment target, but retain a
        // device-orientation fallback for the short interval while cameras switch.
        let fallback: CGFloat
        switch UIDevice.current.orientation {
        case .landscapeLeft: fallback = 0
        case .landscapeRight: fallback = 180
        case .portraitUpsideDown: fallback = 270
        case .portrait: fallback = 90
        default: fallback = lastStableRotationAngle
        }
        return CaptureLayout.normalizedRotationAngle(fallback)
    }

    private func installRotationCoordinator(for device: AVCaptureDevice) {
        rotationObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, _ in
            self?.sessionQueue.async { self?.configureConnections() }
        }
    }

    private func configureConnections() {
        let angle = currentRotationAngle
        lastStableRotationAngle = angle
        func rotate(_ connection: AVCaptureConnection) {
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            } else if connection.isVideoOrientationSupported {
                switch angle {
                case 0: connection.videoOrientation = .landscapeRight
                case 180: connection.videoOrientation = .landscapeLeft
                case 270: connection.videoOrientation = .portraitUpsideDown
                default: connection.videoOrientation = .portrait
                }
            }
        }
        if let photoConnection = photoOutput.connection(with: .video) {
            rotate(photoConnection)
            // 前置自拍按真实方向保存（不镜像）
            if photoConnection.isVideoMirroringSupported { photoConnection.automaticallyAdjustsVideoMirroring = false; photoConnection.isVideoMirrored = false }
        }
        if let videoConnection = videoOutput.connection(with: .video) {
            // Analysis frames are physically rotated upright (portrait or landscape); Vision uses .up.
            rotate(videoConnection)
            if videoConnection.isVideoMirroringSupported { videoConnection.automaticallyAdjustsVideoMirroring = false; videoConnection.isVideoMirrored = false }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.previewRotationAngle != angle { self.previewRotationAngle = angle }
            self.orientationLabel = CaptureLayout.isLandscape(rotationAngle: angle) ? "横拍 4:3" : "竖拍 3:4"
        }
    }

    // MARK: - 设备与变焦

    private func removeCurrentInput() {
        zoomRangeObservations.forEach { $0.invalidate() }
        zoomRangeObservations.removeAll()
        zoomObservation?.invalidate()
        zoomObservation = nil
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
        if let input {
            session.removeInput(input)
            self.input = nil
        }
        currentDevice = nil
    }

    /// Restore a working input if the requested camera is unavailable.
    private func replaceCamera(position: AVCaptureDevice.Position, userZoom: CGFloat) -> Bool {
        let previousInput = input
        let previousDevice = currentDevice
        removeCurrentInput()
        if installCamera(position: position, userZoom: userZoom) { return true }
        if let previousInput, session.canAddInput(previousInput) {
            session.addInput(previousInput)
            input = previousInput
            currentDevice = previousDevice
            if let previousDevice {
                installRotationCoordinator(for: previousDevice)
                observeZoom(previousDevice)
            }
        }
        return false
    }

    private func bestBackDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera,
                                                   .builtInDualWideCamera,
                                                   .builtInDualCamera,
                                                   .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                         mediaType: .video,
                                                         position: .back)
        return types.compactMap { type in discovery.devices.first { $0.deviceType == type } }.first
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func ultraWideDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
    }

    private func wantsUltraWide(_ userZoom: CGFloat) -> Bool {
        userZoom < 1
    }

    @discardableResult
    private func installCamera(position: AVCaptureDevice.Position, userZoom: CGFloat) -> Bool {
        var device: AVCaptureDevice?
        if position == .front {
            device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        } else {
            let primary = bestBackDevice()
            let virtualUltra = primary?.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera } ?? false
            device = !virtualUltra && userZoom < 1 ? (ultraWideDevice() ?? primary) : primary
        }

        guard let device,
              let newInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(newInput) else { return false }

        session.addInput(newInput)
        input = newInput
        currentDevice = device
        installRotationCoordinator(for: device)
        observeZoom(device)
        stateLock.lock()
        currentPosition = position
        stateLock.unlock()

        engine.configure(device)
        lastBias = device.exposureTargetBias
        lastBiasTime = 0
        applyDeviceZoom(device, factor: deviceZoomFactor(device, userZoom: userZoom))
        publishHardwareState(device)

        let aperture = device.lensAperture
        DispatchQueue.main.async {
            self.cameraPosition = position
            self.apertureText = String(format: "f/%.1f", aperture)
        }
        return true
    }

    private func deviceZoomFactor(_ device: AVCaptureDevice, userZoom: CGFloat) -> CGFloat {
        if device.deviceType == .builtInUltraWideCamera { return max(1, userZoom * 2) }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let base = hasUltraWide ? (device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2) : 1
        return userZoom * CGFloat(base)
    }

    private func applyDeviceZoom(_ device: AVCaptureDevice, factor: CGFloat) {
        do {
            try NextLevelDeviceControls.zoom(device, factor: factor, animated: session.isRunning)
        } catch {
            publishError("变焦配置失败：\(error.localizedDescription)")
        }
    }

    // Adapted from NextLevel.addCaptureDeviceObservers: publish measured hardware zoom.
    // Compute the lens normalization once on the session queue; the KVO closure never
    // reads mutable session/input state from the callback thread.
    private func observeZoom(_ device: AVCaptureDevice) {
        zoomRangeObservations.forEach { $0.invalidate() }
        zoomRangeObservations.removeAll()
        zoomObservation?.invalidate()
        let base = deviceZoomFactor(device, userZoom: 1)
        zoomRangeObservations = [
            device.observe(\.minAvailableVideoZoomFactor, options: [.new]) { [weak self] _, _ in
                self?.sessionQueue.async { [weak self] in self?.updateZoomOptions() }
            },
            device.observe(\.maxAvailableVideoZoomFactor, options: [.new]) { [weak self] _, _ in
                self?.sessionQueue.async { [weak self] in self?.updateZoomOptions() }
            }
        ]
        zoomObservation = device.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] device, _ in
            let measured = device.videoZoomFactor / base
            DispatchQueue.main.async { self?.zoom = measured }
        }
    }

    private var isCaptureInFlight: Bool {
        stateLock.lock()
        let value = captureInFlight > 0
        stateLock.unlock()
        return value
    }

    func setZoom(_ userZoom: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard userZoom.isFinite else { return }
            let bounds = self.zoomBounds()
            let target = max(bounds.lowerBound, min(100, min(userZoom, bounds.upperBound)))
            if self.isCaptureInFlight {
                self.stateLock.lock()
                self.pendingUserZoom = target
                self.stateLock.unlock()
                return
            }
            self.applyUserZoom(target)
        }
    }

    private func applyUserZoom(_ target: CGFloat) {
        guard !isConfiguring else { return }
        let virtualUltra = currentDevice?.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera } ?? false
        let needsUltra = currentPosition == .back && !virtualUltra && wantsUltraWide(target) && ultraWideDevice() != nil
        let deviceIsUltra = currentDevice?.deviceType == .builtInUltraWideCamera

        if needsUltra != deviceIsUltra {
            session.beginConfiguration()
            let installed = replaceCamera(position: currentPosition, userZoom: target)
            configureAdvancedCaptureSupport()
            configureConnections()
            session.commitConfiguration()
            if !installed {
                publishError("切换镜头失败")
                return
            }
        } else if let device = currentDevice {
            applyDeviceZoom(device, factor: deviceZoomFactor(device, userZoom: target))
        }

        updateZoomOptions()

    }

    /// All values are displayed relative to the wide-angle camera's 1× field of view.
    /// Virtual cameras cover the full range without rebuilding the session while pinching.
    private func zoomBounds() -> ClosedRange<CGFloat> {
        guard let device = currentDevice else { return 1...1 }
        let base = deviceZoomFactor(device, userZoom: 1)
        var minimum = device.minAvailableVideoZoomFactor / base
        var maximum = min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor) / base
        if currentPosition == .back {
            // Fallback for devices without a virtual ultra-wide camera.
            if device.deviceType == .builtInUltraWideCamera, let wide = bestBackDevice() {
                let wideBase = deviceZoomFactor(wide, userZoom: 1)
                maximum = min(wide.maxAvailableVideoZoomFactor, wide.activeFormat.videoMaxZoomFactor) / wideBase
            } else if !device.isVirtualDevice, ultraWideDevice() != nil { minimum = min(minimum, 0.5) }
        }
        minimum = max(0.01, minimum)
        return minimum...max(minimum, min(100, maximum))
    }

    private func updateZoomOptions() {
        let bounds = zoomBounds()
        var values: [CGFloat] = [bounds.lowerBound, 1, 2, bounds.upperBound]
        var nativeMaximum: CGFloat = 1
        if let device = currentDevice {
            let base = deviceZoomFactor(device, userZoom: 1)
            let native = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) / base }
            values += native
            nativeMaximum = max(1, native.max() ?? 1)
        }
        let sorted = values.filter { bounds.contains($0) }.sorted()
        var result: [CGFloat] = []
        for value in sorted where !result.contains(where: { abs($0 - value) < 0.01 }) { result.append(value) }
        DispatchQueue.main.async {
            self.nativeMaximumZoom = nativeMaximum
            self.minimumZoom = bounds.lowerBound
            self.maximumZoom = bounds.upperBound
            self.availableZooms = result
        }
    }

    func setDepthDelivery(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedDepthDelivery = enabled
            guard self.currentDevice != nil else { return }
            if self.isCaptureInFlight { self.depthConfigurationPending = true; return }
            self.refreshDepthConfiguration()
        }
    }

    private func refreshDepthConfiguration() {
        session.beginConfiguration()
        configureAdvancedCaptureSupport()
        session.commitConfiguration()
        depthConfigurationPending = false
        updateZoomOptions()
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfiguring, !self.isCaptureInFlight else { return }
            let next: AVCaptureDevice.Position = self.currentPosition == .back ? .front : .back

            self.session.beginConfiguration()
            let installed = self.replaceCamera(position: next, userZoom: 1)
            self.configureAdvancedCaptureSupport()
            self.configureConnections()
            self.session.commitConfiguration()

            if installed {
                self.updateZoomOptions()
                DispatchQueue.main.async { self.zoom = 1 }
            } else {
                self.publishError("切换前后摄像头失败")
            }
        }
    }

    // MARK: - 对焦 / 曝光

    func setFocusAndExposure(normalizedPoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = normalizedPoint
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported && !self.directorOwnsExposure {
                    device.exposurePointOfInterest = normalizedPoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch {
            }
        }
    }

    func setUserExposure(_ bias: Float?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.userBias = bias ?? 0
            DispatchQueue.main.async { self.manualExposure = bias != nil }
            guard let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                device.setExposureTargetBias(max(device.minExposureTargetBias, min(device.maxExposureTargetBias, self.userBias)), completionHandler: nil)
            } catch { }
        }
    }
    func setFocusExposureLock(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                let focus: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
                let exposure: AVCaptureDevice.ExposureMode = locked ? .locked : .continuousAutoExposure
                if device.isFocusModeSupported(focus) { device.focusMode = focus }
                if !self.directorOwnsExposure && device.isExposureModeSupported(exposure) { device.exposureMode = exposure }
                DispatchQueue.main.async { self.focusExposureLocked = locked }
            } catch { }
        }
    }

    /// Motion intent uses supported custom exposure only. Other intents restore AE.
    func applyMotionExposure(enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice, !self.isCaptureInFlight else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if !enabled {
                    if self.directorOwnsExposure && device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    self.directorOwnsExposure = false
                    return
                }
                guard device.isExposureModeSupported(.custom), Date().timeIntervalSince(self.lastMotionExposureUpdate) > 1 else { return }
                let format = device.activeFormat
                let minimum = CMTimeGetSeconds(format.minExposureDuration)
                let maximum = CMTimeGetSeconds(format.maxExposureDuration)
                guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return }
                let duration = max(minimum, min(maximum, 1.0 / 500))
                let old = CMTimeGetSeconds(device.exposureDuration)
                guard old.isFinite, old > 0 else { return }
                let correction = pow(2.0, -Double(device.exposureTargetOffset))
                let targetISO = Double(device.iso) * old / duration * max(0.5, min(2, correction))
                let iso = max(format.minISO, min(format.maxISO, Float(targetISO)))
                device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000), iso: iso, completionHandler: nil)
                self.directorOwnsExposure = true
                self.lastMotionExposureUpdate = Date()
            } catch { /* Retain normal exposure; do not claim a command succeeded. */ }
        }
    }

    /// 只做曝光补偿：所有机型都支持，且不会抢走系统的连续自动曝光。
    func applyExposureCompensation(brightness: Double, directorBias: Float? = nil) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }

            let seconds = CMTimeGetSeconds(device.exposureDuration)
            let exposure = seconds > 0 && seconds < 1 ? String(format: "1/%.0fs", 1 / seconds) : String(format: "%.2fs", seconds)
            let telemetry = String(format: "ISO %.0f · ", device.iso) + exposure
            let settled = !device.isAdjustingFocus && !device.isAdjustingExposure && !device.isRampingVideoZoom
            DispatchQueue.main.async {
                self.exposureSeconds = seconds
                self.exposureText = telemetry
                self.controlsSettled = settled
                self.controlsUpdatedAt = Date()
            }

            guard !self.manualExposure, !self.focusExposureLocked else { return }
            var target: Float
            if brightness < 0.16 {
                target = 0.4
            } else if brightness < 0.22 {
                target = 0.2
            } else if brightness > 0.90 {
                target = -0.5
            } else if brightness > 0.82 {
                target = -0.25
            } else {
                target = 0
            }
            if let directorBias, abs(directorBias) > 0.01 { target += directorBias }
            target = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, target))

            let now = CFAbsoluteTimeGetCurrent()
            guard abs(target - self.lastBias) >= 0.15, now - self.lastBiasTime >= 0.6 else { return }

            do {
                if try NextLevelDeviceControls.expose(device, targetBias: target) {
                    self.lastBias = target
                    self.lastBiasTime = now
                }

            } catch {
            }
        }
    }

    // MARK: - 拍照

    func setHighQualityMode(_ enabled: Bool) {
        highQualityMode = enabled
        sessionQueue.async { self.requestedHighQuality = enabled }
    }

    func capture() {
        let flashRequested = requestedFlash
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning, !self.isConfiguring, !self.isCaptureInFlight else { return }

            let settings = AVCapturePhotoSettings()
            settings.flashMode = flashRequested && self.photoOutput.supportedFlashModes.contains(.on) ? .on : .off

            self.engine.prepare(settings, output: self.photoOutput, highQuality: self.requestedHighQuality)
            if self.directorOwnsExposure { settings.photoQualityPrioritization = .speed }
            self.configureConnections()

            self.stateLock.lock()
            self.captureInFlight += 1
            self.stateLock.unlock()

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    private func publishHardwareState(_ device: AVCaptureDevice) {
        let profile = engine.profile
        let supportsFlash = photoOutput.supportedFlashModes.contains(.on)
        let hdr = device.activeFormat.isVideoHDRSupported && device.isVideoHDREnabled
        let lowLight = device.isLowLightBoostEnabled
        DispatchQueue.main.async {
            self.flashAvailable = supportsFlash
            self.cameraEngineSummary = profile.summary
            self.cameraEngineTier = profile.tier.rawValue
            self.lowLightBoostActive = lowLight
            self.hardwareHDRActive = hdr
        }
    }
}

// MARK: - 视频帧

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        stateLock.lock()
        let position = currentPosition
        stateLock.unlock()
        let time = ProcessInfo.processInfo.systemUptime
        if time - lastThumbnailTime > 1.5, !thumbnailBusy, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lastThumbnailTime = time; thumbnailBusy = true
            thumbnailQueue.async { [weak self] in
                guard let self else { return }
                let image: UIImage? = autoreleasepool {
                    let input = CIImage(cvPixelBuffer: buffer)
                    let scale = 240 / max(input.extent.width, input.extent.height)
                    let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    return ImagePipeline.context.createCGImage(small, from: small.extent).map { UIImage(cgImage: $0) }
                }
                DispatchQueue.main.async { self.previewThumbnail = image }
                self.videoQueue.async { self.thumbnailBusy = false }
            }
        }
        onFrame?(sampleBuffer, position)
        realtimePreview.consume(sampleBuffer)
    }
}

// MARK: - 拍照回调

extension CameraService: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        stateLock.lock()
        captureInFlight = max(0, captureInFlight - 1)
        let pending = pendingUserZoom
        pendingUserZoom = nil
        stateLock.unlock()

        if let error {
            publishError("拍照失败：\(error.localizedDescription)")
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.depthConfigurationPending { self.refreshDepthConfiguration() }
            if let pending { self.applyUserZoom(pending) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            publishError("照片处理失败：\(error.localizedDescription)")
            return
        }
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            publishError("照片数据无法解码")
            return
        }
        let matte = photo.portraitEffectsMatte

        photoQueue.async { [weak self] in
            guard let self else { return }
            var portrait: UIImage?
            var mask: UIImage?
            if let matte {
                portrait = DepthPortraitProcessor.makePortrait(image: image, matte: matte)
                mask = DepthPortraitProcessor.makePortraitMask(image: image, matte: matte)
            }
            let captured = CapturedPhoto(originalData: data,
                                         image: image,
                                         depthPortrait: portrait,
                                         depthMask: mask,
                                         capturedAt: Date())
            DispatchQueue.main.async {
                self.errorMessage = nil
                self.latestPhoto = captured
                self.photoToken = UUID()
            }
        }
    }
}

// MARK: - 预览

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraService
    var options: PhotoRenderOptions
    var effectsEnabled: Bool
    var autoFocusPoint: CGPoint? = nil
    var focusObservationTick: Int = 0
    var onSubjectTap: ((CGPoint, Bool) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let service = camera
        let view = PreviewView()
        view.previewLayer.session = service.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onTap = { [weak service] point in
            service?.setFocusAndExposure(normalizedPoint: point)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        camera.realtimePreview.configure(options: options, enabled: effectsEnabled) { [weak uiView] cg in
            uiView?.effectImage.image = cg.map { UIImage(cgImage: $0) }
            uiView?.effectImage.isHidden = cg == nil
        }
        uiView.onSubjectTap = onSubjectTap
        uiView.processor = camera.realtimePreview
        if !camera.focusExposureLocked, let point = autoFocusPoint, uiView.lastFocusTick != focusObservationTick,
           Date().timeIntervalSince(uiView.lastFocusAt) > 1.2,
           Date().timeIntervalSince(uiView.lastTapAt) > 5, uiView.bounds.width > 0,
           uiView.lastFocusPoint.map({ hypot($0.x - point.x, $0.y - point.y) > 0.06 }) ?? true {
            uiView.lastFocusTick = focusObservationTick
            uiView.lastFocusAt = Date()
            uiView.lastFocusPoint = point
            let imageSize = uiView.effectImage.image?.size ?? CGSize(width: 3, height: 4)
            let scale = max(uiView.bounds.width / imageSize.width, uiView.bounds.height / imageSize.height)
            let layerPoint = CGPoint(x: (point.x - 0.5) * imageSize.width * scale + uiView.bounds.midX,
                                     y: (0.5 - point.y) * imageSize.height * scale + uiView.bounds.midY)
            let converted = uiView.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            if (0...1).contains(converted.x), (0...1).contains(converted.y) {
                camera.setFocusAndExposure(normalizedPoint: converted)
            }
        }
        if let connection = uiView.previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
            let angle = camera.previewRotationAngle
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}

final class PreviewView: UIView {
    let effectImage = UIImageView()
    var lastFocusTick = -1
    var lastFocusPoint: CGPoint?
    var lastFocusAt = Date.distantPast
    var lastTapAt = Date.distantPast
    weak var processor: RealtimePreviewProcessor?
    deinit { processor?.detach() }
    override func layoutSubviews() {
        super.layoutSubviews()
        effectImage.frame = bounds
    }
    private func setupEffectImage() {
        effectImage.contentMode = .scaleAspectFill
        effectImage.clipsToBounds = true
        effectImage.isUserInteractionEnabled = false
        effectImage.isHidden = true
        addSubview(effectImage)
    }
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    /// Never force-cast the backing layer: a SwiftUI re-parent or a container
    /// change would turn a cosmetic change into a crash. Falls back to a
    /// detached preview layer if the layer class ever differs.
    var previewLayer: AVCaptureVideoPreviewLayer {
        if let layer = layer as? AVCaptureVideoPreviewLayer { return layer }
        let fallback = AVCaptureVideoPreviewLayer()
        fallback.videoGravity = .resizeAspectFill
        fallback.frame = bounds
        layer.addSublayer(fallback)
        return fallback
    }

    var onTap: ((CGPoint) -> Void)?
    var onSubjectTap: ((CGPoint, Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        setupEffectImage()
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(recognizer)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = true
        setupEffectImage()
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(recognizer)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        addGestureRecognizer(hold)
    }

    private func visionPoint(_ point: CGPoint) -> CGPoint {
        let image = effectImage.image?.size ?? CGSize(width: 3, height: 4)
        let scale = max(bounds.width / image.width, bounds.height / image.height)
        return CGPoint(x: max(0, min(1, (point.x - bounds.midX) / (image.width * scale) + 0.5)),
                       y: max(0, min(1, 0.5 - (point.y - bounds.midY) / (image.height * scale))))
    }
    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        lastTapAt = Date()
        let point = recognizer.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        onSubjectTap?(visionPoint(point), true)
    }
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        lastTapAt = Date()
        let layerPoint = recognizer.location(in: self)
        // 交给系统做方向/镜像/aspectFill 的换算，避免手算错位
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onTap?(devicePoint)
        onSubjectTap?(visionPoint(layerPoint), false)
    }
}
