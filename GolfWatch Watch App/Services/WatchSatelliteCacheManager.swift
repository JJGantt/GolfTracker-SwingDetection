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
        let hasCached = availableCourses.contains(courseId)
        print("⌚ [SatelliteCache] hasCachedImages for \(courseId): \(hasCached)")
        print("⌚ [SatelliteCache] Available courses: \(availableCourses)")
        return hasCached
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

        print("⌚ [SatelliteCache] 📥 Saving image for hole \(metadata.holeNumber), courseId: \(metadata.courseId)")
        print("⌚ [SatelliteCache] Image URL: \(imageURL.path)")

        do {
            try imageData.write(to: imageURL)
            print("⌚ [SatelliteCache] ✅ Saved image for hole \(metadata.holeNumber): \(imageData.count / 1024)KB")

            // Update metadata
            updateMetadata(metadata: metadata)

            // Update available courses
            print("⌚ [SatelliteCache] 📝 Before insert - Available courses: \(availableCourses)")
            DispatchQueue.main.async {
                self.availableCourses.insert(metadata.courseId)
                print("⌚ [SatelliteCache] ✅ After insert - Available courses: \(self.availableCourses)")
                print("⌚ [SatelliteCache] 🔄 Published state updated for course: \(metadata.courseId)")
            }
        } catch {
            print("⌚ [SatelliteCache] ❌ ERROR saving image: \(error)")
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
        print("⌚ [SatelliteCache] 🔄 Loading available courses from disk...")
        guard let allCaches = loadMetadata() else {
            print("⌚ [SatelliteCache] No metadata found on disk")
            return
        }
        availableCourses = Set(allCaches.map { $0.courseId })
        print("⌚ [SatelliteCache] ✅ Loaded \(availableCourses.count) courses: \(availableCourses)")
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
        print("⌚ [SatelliteCache] 📝 Updating metadata for hole \(metadata.holeNumber), courseId: \(metadata.courseId)")
        var allCaches = loadMetadata() ?? []

        if let cacheIndex = allCaches.firstIndex(where: { $0.courseId == metadata.courseId }) {
            // Course cache exists, update or add image metadata
            print("⌚ [SatelliteCache] Found existing course cache at index \(cacheIndex)")
            if let imageIndex = allCaches[cacheIndex].images.firstIndex(where: { $0.holeNumber == metadata.holeNumber }) {
                print("⌚ [SatelliteCache] Updating existing hole \(metadata.holeNumber)")
                allCaches[cacheIndex].images[imageIndex] = metadata
            } else {
                print("⌚ [SatelliteCache] Adding new hole \(metadata.holeNumber)")
                allCaches[cacheIndex].images.append(metadata)
            }
            allCaches[cacheIndex].lastUpdated = Date()
        } else {
            // Create new course cache
            print("⌚ [SatelliteCache] Creating new course cache for \(metadata.courseId)")
            let newCache = CourseSatelliteCache(courseId: metadata.courseId, courseName: "", images: [metadata])
            allCaches.append(newCache)
        }

        saveMetadata(allCaches)
        print("⌚ [SatelliteCache] ✅ Metadata saved. Total courses: \(allCaches.count)")
    }
}
