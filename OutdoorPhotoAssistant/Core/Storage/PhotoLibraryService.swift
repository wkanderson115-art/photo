import Combine
import Foundation
import ImageIO
import Photos
import UIKit

/// 相册服务。
///
/// 关键改动：
/// - 原片按"原始字节"写入相册（保留 EXIF / GPS / 深度 / 人像光），而不是把 UIImage 重新编码（上一版会丢掉全部元数据）；
/// - 成片用 JPEG（质量 0.95）写入；
/// - 只请求一次读授权，缩略图管理器复用；
/// - 保存失败会通过 lastSaveError 暴露给 UI，不再静默。
final class PhotoLibraryService: ObservableObject {
    @Published var recent: [UIImage] = []
    @Published var accessDenied = false
    @Published var lastSaveError: String?

    private let imageManager = PHCachingImageManager()
    private var didLoad = false
    private var loadGeneration = UUID()

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        load()
    }

    func load() {
        didLoad = true
        let generation = UUID()
        loadGeneration = generation
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                DispatchQueue.main.async {
                    self?.handleLoadAuthorization(newStatus, generation: generation)
                }
            }
        default:
            handleLoadAuthorization(status, generation: generation)
        }
    }

    private func handleLoadAuthorization(_ status: PHAuthorizationStatus, generation: UUID) {
        guard generation == loadGeneration else { return }
        guard status == .authorized || status == .limited else {
            DispatchQueue.main.async { self.accessDenied = true }
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 30
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        let request = PHImageRequestOptions()
        request.deliveryMode = .fastFormat
        request.resizeMode = .fast
        request.isSynchronous = false
        request.isNetworkAccessAllowed = false

        var collected: [(Int, UIImage)] = []
        let lock = NSLock()
        let group = DispatchGroup()

        assets.enumerateObjects { asset, index, _ in
            group.enter()
            var completed = false
            self.imageManager.requestImage(for: asset,
                                           targetSize: CGSize(width: 320, height: 320),
                                           contentMode: .aspectFill,
                                           options: request) { image, _ in
                lock.lock()
                guard !completed else { lock.unlock(); return }
                completed = true
                if let image { collected.append((index, image)) }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, generation == self.loadGeneration else { return }
            self.accessDenied = false
            self.recent = collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    /// 保存一次拍摄：原片字节 + 成片 JPEG。
    func saveShot(originalData: Data,
                  styledImage: UIImage,
                  keepOriginal: Bool = true,
                  completion: ((Bool) -> Void)? = nil) {
        guard let styledData = styledImage.jpegData(compressionQuality: 0.95) else {
            DispatchQueue.main.async { [weak self] in
                self?.lastSaveError = "照片编码失败，未保存任何照片"
                completion?(false)
            }
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self?.lastSaveError = "没有相册写入权限，请到系统设置里允许"
                    completion?(false)
                }
                return
            }

            let originalType = Self.uniformTypeIdentifier(for: originalData)

            PHPhotoLibrary.shared().performChanges({
                if keepOriginal {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = originalType
                    request.addResource(with: .photo, data: originalData, options: options)
                }
                do {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = "public.jpeg"
                    request.addResource(with: .photo, data: styledData, options: options)
                }
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    self?.lastSaveError = error?.localizedDescription
                    if success, self?.didLoad == true { self?.load() }
                    completion?(success)
                }
            })
        }
    }

    private static func uniformTypeIdentifier(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return "public.jpeg"
        }
        return type as String
    }
}
