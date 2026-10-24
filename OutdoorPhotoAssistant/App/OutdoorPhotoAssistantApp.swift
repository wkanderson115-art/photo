import SwiftUI

@main
struct OutdoorPhotoAssistantApp: App {
    @StateObject private var camera = CameraService()
    @StateObject private var motion = MotionService()
    @StateObject private var analyzer = FrameAnalyzer()
    @StateObject private var location = LocationService()
    @StateObject private var library = PhotoLibraryService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(camera)
                .environmentObject(motion)
                .environmentObject(analyzer)
                .environmentObject(location)
                .environmentObject(library)
                .onAppear {
                    APIKeyStore.removeLegacyBackendSession()
                    let analyzerRef = self.analyzer
                    self.camera.onFrame = { buffer, position in
                        analyzerRef.analyze(buffer, position: position)
                    }
                }
        }
    }
}
