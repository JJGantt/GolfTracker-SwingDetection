import Foundation
import UIKit

class WatchSatelliteCacheManager: ObservableObject {
    static let shared = WatchSatelliteCacheManager()

    @Published var availableCourses: Set<UUID> = []

    private let cacheDirectoryName = "SatelliteCache"
    private let metadataFileName = "satelliteCache.json"

    private var cacheDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(cacheDirectoryName)
    }

    private init() {
        createCacheDirectoryIfNeeded()
        loadAvailableCourses()
    }

    // MARK: - Public API

    func hasCachedImages(for courseId: UUID) -> Bool {
        return availableCourses.contains(courseId)
    }

    func getImage(for courseId: UUID, holeNumber: Int) -> UIImage? {
        guard let metadata = getMetadata(for: courseId, holeNumber: holeNumber) else {
            return nil
        }

        let imageURL = getImageURL(for: courseId, fileName: metadata.fileName)
        guard let data = try? Data(contentsOf: imageURL) else {
            return nil
        }

        return UIImage(data: data)
    }

    func getMetadata(for courseId: UUID, holeNumber: Int) -> SatelliteImageMetadata? {
        guard let cache = getCachedImages(for: courseId) else {
            return nil
        }

        return cache.images.first { $0.holeNumber == holeNumber }
    }

    func saveImage(metadata: SatelliteImageMetadata, imageData: Data) {
        let imageURL = getImageURL(for: metadata.courseId, fileName: metadata.fileName)

        do {
            try imageData.write(to: imageURL)
            print("⌚ [SatelliteCache] Saved image for hole \(metadata.holeNumber): \(imageData.count / 1024)KB")

            // Update metadata
            updateMetadata(metadata: metadata)

            // Update available courses
            DispatchQueue.main.async {
                self.availableCourses.insert(metadata.courseId)
            }
        } catch {
            print("⌚ [SatelliteCache] ERROR saving image: \(error)")
        }
    }

    func deleteCacheForCourse(_ courseId: UUID) {
        let courseCacheURL = cacheDirectory.appendingPathComponent(courseId.uuidString)
        try? FileManager.default.removeItem(at: courseCacheURL)

        // Update metadata
        if var allCaches = loadMetadata() {
            allCaches.removeAll { $0.courseId == courseId }
            saveMetadata(allCaches)
        }

        DispatchQueue.main.async {
            self.availableCourses.remove(courseId)
        }
    }

    // MARK: - Private Implementation

    private func getCachedImages(for courseId: UUID) -> CourseSatelliteCache? {
        guard let metadata = loadMetadata() else { return nil }
        return metadata.first { $0.courseId == courseId }
    }

    private func getImageURL(for courseId: UUID, fileName: String) -> URL {
        let courseCacheURL = cacheDirectory.appendingPathComponent(courseId.uuidString)
        try? FileManager.default.createDirectory(at: courseCacheURL, withIntermediateDirectories: true)
        return courseCacheURL.appendingPathComponent(fileName)
    }

    private func createCacheDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func loadAvailableCourses() {
        guard let allCaches = loadMetadata() else { return }
        availableCourses = Set(allCaches.map { $0.courseId })
    }

    // MARK: - Metadata Management

    private func loadMetadata() -> [CourseSatelliteCache]? {
        let metadataURL = cacheDirectory.appendingPathComponent(metadataFileName)
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode([CourseSatelliteCache].self, from: data)
    }

    private func saveMetadata(_ caches: [CourseSatelliteCache]) {
        let metadataURL = cacheDirectory.appendingPathComponent(metadataFileName)
        guard let data = try? JSONEncoder().encode(caches) else { return }
        try? data.write(to: metadataURL)
    }

    private func updateMetadata(metadata: SatelliteImageMetadata) {
        var allCaches = loadMetadata() ?? []

        if let cacheIndex = allCaches.firstIndex(where: { $0.courseId == metadata.courseId }) {
            // Course cache exists, update or add image metadata
            if let imageIndex = allCaches[cacheIndex].images.firstIndex(where: { $0.holeNumber == metadata.holeNumber }) {
                allCaches[cacheIndex].images[imageIndex] = metadata
            } else {
                allCaches[cacheIndex].images.append(metadata)
            }
            allCaches[cacheIndex].lastUpdated = Date()
        } else {
            // Create new course cache
            let newCache = CourseSatelliteCache(courseId: metadata.courseId, courseName: "", images: [metadata])
            allCaches.append(newCache)
        }

        saveMetadata(allCaches)
    }
}
