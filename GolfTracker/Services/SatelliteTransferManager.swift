import Foundation
import WatchConnectivity

class SatelliteTransferManager {
    static let shared = SatelliteTransferManager()

    private let cacheManager = SatelliteCacheManager.shared

    private init() {}

    /// Transfer all cached images for a course to Watch
    func transferImages(for courseId: UUID, completion: @escaping (Bool) -> Void) {
        guard let cache = cacheManager.getCachedImages(for: courseId) else {
            print("📡 [Transfer] No cached images found for course")
            completion(false)
            return
        }

        print("📡 [Transfer] Starting transfer of \(cache.images.count) images")

        transferImagesSequentially(cache: cache, index: 0, completion: completion)
    }

    /// Transfer a single hole image to Watch
    func transferHoleImage(courseId: UUID, holeNumber: Int, completion: @escaping (Bool) -> Void) {
        guard let imageData = cacheManager.getImageData(for: courseId, holeNumber: holeNumber),
              let cache = cacheManager.getCachedImages(for: courseId),
              let metadata = cache.images.first(where: { $0.holeNumber == holeNumber }) else {
            print("📡 [Transfer] No image data for hole \(holeNumber)")
            completion(false)
            return
        }

        transferSingleImage(metadata: metadata, imageData: imageData, completion: completion)
    }

    // MARK: - Private Implementation

    private func transferImagesSequentially(cache: CourseSatelliteCache, index: Int, completion: @escaping (Bool) -> Void) {
        guard index < cache.images.count else {
            // All images transferred
            print("📡 [Transfer] All images transferred successfully")
            completion(true)
            return
        }

        let imageMetadata = cache.images[index]

        guard let imageData = cacheManager.getImageData(for: cache.courseId, holeNumber: imageMetadata.holeNumber) else {
            print("📡 [Transfer] ERROR: Failed to get image data for hole \(imageMetadata.holeNumber)")
            transferImagesSequentially(cache: cache, index: index + 1, completion: completion)
            return
        }

        transferSingleImage(metadata: imageMetadata, imageData: imageData) { success in
            if success {
                print("📡 [Transfer] Transferred hole \(imageMetadata.holeNumber): \(imageData.count / 1024)KB")
            } else {
                print("📡 [Transfer] ERROR: Failed to transfer hole \(imageMetadata.holeNumber)")
            }

            // Continue with next image regardless of success
            self.transferImagesSequentially(cache: cache, index: index + 1, completion: completion)
        }
    }

    private func transferSingleImage(metadata: SatelliteImageMetadata, imageData: Data, completion: @escaping (Bool) -> Void) {
        guard WCSession.default.activationState == .activated else {
            print("📡 [Transfer] ❌ WCSession not activated")
            completion(false)
            return
        }

        print("📡 [Transfer] 📤 Preparing to transfer hole \(metadata.holeNumber), courseId: \(metadata.courseId)")
        print("📡 [Transfer] Image size: \(imageData.count / 1024)KB")

        // Use WCSession.transferFile for large data transfers (automatically queued and reliable)
        do {
            let metadataJSON = try JSONEncoder().encode(metadata)
            let metadataDict: [String: Any] = ["metadata": metadataJSON]

            // Save image to temp file for transfer
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(metadata.fileName)
            try imageData.write(to: tempURL)
            print("📡 [Transfer] 💾 Wrote temp file: \(tempURL.path)")

            WCSession.default.transferFile(tempURL, metadata: metadataDict)
            print("📡 [Transfer] ✅ Queued file transfer for \(metadata.fileName)")
            print("📡 [Transfer] Outstanding transfers: \(WCSession.default.outstandingFileTransfers.count)")
            completion(true)
        } catch {
            print("📡 [Transfer] ❌ ERROR: \(error)")
            completion(false)
        }
    }
}
