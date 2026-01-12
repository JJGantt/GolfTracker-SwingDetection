import Foundation
import MapKit
import UIKit

class SatelliteCacheManager: ObservableObject {
    static let shared = SatelliteCacheManager()

    @Published var downloadProgress: [UUID: Double] = [:] // courseId -> progress (0.0-1.0)
    @Published var isDownloading: [UUID: Bool] = [:]

    private let cacheDirectoryName = "SatelliteCache"
    private let metadataFileName = "satelliteCache.json"

    private var cacheDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(cacheDirectoryName)
    }

    private init() {
        createCacheDirectoryIfNeeded()
    }

    // MARK: - Public API

    /// Download large 2km×2km satellite image for a course
    func downloadLargeSatelliteImage(centerCoordinate: CLLocationCoordinate2D, courseId: UUID, completion: @escaping (Result<LargeSatelliteImageMetadata, Error>) -> Void) {
        let startMsg = "📡 [SatelliteCache] Starting download - Center: (\(centerCoordinate.latitude), \(centerCoordinate.longitude)), Size: 2000x2000px, Radius: 1000m"
        print(startMsg)
        SatelliteLogHandler.shared.log(startMsg)

        DispatchQueue.main.async {
            self.isDownloading[courseId] = true
            self.downloadProgress[courseId] = 0.0
        }

        // Configure snapshotter for 2000×2000 image covering 2km radius
        // (Reduced from 3000×3000 to avoid Apple Maps server errors)
        let radiusMeters: Double = 1000.0 // 2km diameter
        let pixelSize = 2000

        let metadata = LargeSatelliteImageMetadata(
            center: centerCoordinate,
            radiusMeters: radiusMeters,
            pixelWidth: pixelSize,
            pixelHeight: pixelSize
        )
        let regionSpan = MKCoordinateRegion(
            center: centerCoordinate,
            latitudinalMeters: radiusMeters * 2,
            longitudinalMeters: radiusMeters * 2
        )

        let options = MKMapSnapshotter.Options()
        options.region = regionSpan
        options.size = CGSize(width: 2000, height: 2000)
        options.mapType = .satellite
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll

        let snapshotter = MKMapSnapshotter(options: options)

        snapshotter.start { snapshot, error in
            if let error = error {
                let errorMsg = "❌ [SatelliteCache] MapKit snapshotter failed: \(error.localizedDescription)"
                print(errorMsg)
                SatelliteLogHandler.shared.log(errorMsg)

                if let mkError = error as? MKError {
                    let mkErrorMsg = "MKError code: \(mkError.code.rawValue) - \(mkError.localizedDescription)"
                    print(mkErrorMsg)
                    SatelliteLogHandler.shared.log(mkErrorMsg)
                }

                DispatchQueue.main.async {
                    self.isDownloading[courseId] = false
                }
                completion(.failure(error))
                return
            }

            guard let snapshot = snapshot else {
                DispatchQueue.main.async {
                    self.isDownloading[courseId] = false
                }
                completion(.failure(NSError(domain: "SatelliteCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "No snapshot returned"])))
                return
            }

            // Convert to JPEG and save
            guard let jpegData = snapshot.image.jpegData(compressionQuality: 0.85) else {
                DispatchQueue.main.async {
                    self.isDownloading[courseId] = false
                }
                completion(.failure(NSError(domain: "SatelliteCache", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert to JPEG"])))
                return
            }

            let imageURL = self.getLargeImageURL(for: courseId)

            do {
                try jpegData.write(to: imageURL)
                print("📡 [SatelliteCache] Saved large satellite image: \(jpegData.count / 1024 / 1024)MB")

                // Update cache metadata
                self.updateCacheMetadata(courseId: courseId, largeImageMetadata: metadata, newImages: nil)

                DispatchQueue.main.async {
                    self.isDownloading[courseId] = false
                    self.downloadProgress[courseId] = 1.0
                }

                completion(.success(metadata))
            } catch {
                DispatchQueue.main.async {
                    self.isDownloading[courseId] = false
                }
                completion(.failure(error))
            }
        }
    }

    /// Crop 2000×2000 image for a specific hole from the large satellite image
    /// Centers crop on midpoint between userLocation (tee) and hole (pin)
    func cropImageForHole(courseId: UUID, hole: Hole, userLocation: CLLocationCoordinate2D? = nil, completion: @escaping (Result<SatelliteImageMetadata, Error>) -> Void) {
        guard let cache = getCachedImages(for: courseId),
              let largeImageMetadata = cache.largeImage else {
            completion(.failure(NSError(domain: "SatelliteCache", code: -3, userInfo: [NSLocalizedDescriptionKey: "No large satellite image cached"])))
            return
        }

        // Load large image
        let largeImageURL = getLargeImageURL(for: courseId)
        guard let largeImageData = try? Data(contentsOf: largeImageURL),
              let largeImage = UIImage(data: largeImageData),
              let cgImage = largeImage.cgImage else {
            completion(.failure(NSError(domain: "SatelliteCache", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to load large satellite image"])))
            return
        }

        // Calculate crop center - use midpoint if userLocation provided (better utilization)
        let cropCenter: CLLocationCoordinate2D
        if let userLoc = userLocation {
            // Center crop at 45%/50% between user (tee) and hole (pin)
            // This matches the Watch display logic for optimal coverage
            let centerLat = userLoc.latitude + (hole.coordinate.latitude - userLoc.latitude) * 0.45
            let centerLon = userLoc.longitude + (hole.coordinate.longitude - userLoc.longitude) * 0.5
            cropCenter = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
            print("📡 [SatelliteCache] Cropping at midpoint between user and hole")
        } else {
            // Fallback: center on hole (legacy behavior)
            cropCenter = hole.coordinate
            print("📡 [SatelliteCache] Cropping at hole coordinate (no user location provided)")
        }

        // Calculate crop rect
        let cropRect = calculateCropRect(
            holeCoordinate: cropCenter,
            largeImageCenter: largeImageMetadata.centerCoordinate,
            largeImageSize: CGSize(width: CGFloat(largeImageMetadata.pixelWidth), height: CGFloat(largeImageMetadata.pixelHeight)),
            metersPerPixel: largeImageMetadata.metersPerPixel,
            cropSize: CGSize(width: 2000, height: 2000)
        )

        // Calculate the actual center coordinate of the cropped region
        // (may differ from hole coordinate if clamping occurred near edges)
        let cropCenterX = cropRect.origin.x + cropRect.width / 2
        let cropCenterY = cropRect.origin.y + cropRect.height / 2
        let actualCenter = pixelToCoordinate(
            pixelX: cropCenterX,
            pixelY: cropCenterY,
            imageCenter: largeImageMetadata.centerCoordinate,
            imageSize: CGSize(width: CGFloat(largeImageMetadata.pixelWidth), height: CGFloat(largeImageMetadata.pixelHeight)),
            metersPerPixel: largeImageMetadata.metersPerPixel
        )

        // Crop image
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
            completion(.failure(NSError(domain: "SatelliteCache", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to crop image"])))
            return
        }

        let croppedImage = UIImage(cgImage: croppedCGImage)

        // Convert to JPEG and save
        guard let jpegData = croppedImage.jpegData(compressionQuality: 0.85) else {
            completion(.failure(NSError(domain: "SatelliteCache", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to convert crop to JPEG"])))
            return
        }

        // Use actual center of cropped region (accounts for edge clamping)
        let metadata = SatelliteImageMetadata(courseId: courseId, holeNumber: hole.number, center: actualCenter)
        let imageURL = getImageURL(for: courseId, fileName: metadata.fileName)

        do {
            try jpegData.write(to: imageURL)
            print("📡 [SatelliteCache] Cropped and saved image for hole \(hole.number): \(jpegData.count / 1024)KB")

            // Update cache metadata
            updateCacheMetadata(courseId: courseId, largeImageMetadata: nil, newImages: [metadata])

            completion(.success(metadata))
        } catch {
            completion(.failure(error))
        }
    }

    /// Get cached images metadata for a course
    func getCachedImages(for courseId: UUID) -> CourseSatelliteCache? {
        guard let metadata = loadMetadata() else { return nil }
        return metadata.first { $0.courseId == courseId }
    }

    /// Get image data for a specific hole
    func getImageData(for courseId: UUID, holeNumber: Int) -> Data? {
        guard let cache = getCachedImages(for: courseId),
              let imageMetadata = cache.images.first(where: { $0.holeNumber == holeNumber }) else {
            return nil
        }

        let imageURL = getImageURL(for: courseId, fileName: imageMetadata.fileName)
        return try? Data(contentsOf: imageURL)
    }

    /// Delete cache for a course
    func deleteCacheForCourse(_ courseId: UUID) {
        let courseCacheURL = cacheDirectory.appendingPathComponent(courseId.uuidString)
        try? FileManager.default.removeItem(at: courseCacheURL)

        // Update metadata
        if var metadata = loadMetadata() {
            metadata.removeAll { $0.courseId == courseId }
            saveMetadata(metadata)
        }
    }

    // MARK: - Private Helpers

    private func pixelToCoordinate(
        pixelX: CGFloat,
        pixelY: CGFloat,
        imageCenter: CLLocationCoordinate2D,
        imageSize: CGSize,
        metersPerPixel: Double
    ) -> CLLocationCoordinate2D {
        // Convert pixel offset from image center to meters
        let pixelOffsetX = pixelX - (imageSize.width / 2)
        let pixelOffsetY = pixelY - (imageSize.height / 2)

        let metersEast = Double(pixelOffsetX) * metersPerPixel
        let metersNorth = -Double(pixelOffsetY) * metersPerPixel  // Negative because Y increases downward

        // Convert meters to degrees
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(imageCenter.latitude * .pi / 180.0)

        let deltaLat = metersNorth / metersPerDegreeLat
        let deltaLon = metersEast / metersPerDegreeLon

        return CLLocationCoordinate2D(
            latitude: imageCenter.latitude + deltaLat,
            longitude: imageCenter.longitude + deltaLon
        )
    }

    private func calculateCropRect(
        holeCoordinate: CLLocationCoordinate2D,
        largeImageCenter: CLLocationCoordinate2D,
        largeImageSize: CGSize,
        metersPerPixel: Double,
        cropSize: CGSize
    ) -> CGRect {
        // Calculate meters offset from large image center
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(largeImageCenter.latitude * .pi / 180.0)

        let deltaLat = holeCoordinate.latitude - largeImageCenter.latitude
        let deltaLon = holeCoordinate.longitude - largeImageCenter.longitude

        let metersNorth = deltaLat * metersPerDegreeLat
        let metersEast = deltaLon * metersPerDegreeLon

        // Convert to pixels on large image
        let pixelX = (metersEast / metersPerPixel) + (largeImageSize.width / 2)
        let pixelY = -(metersNorth / metersPerPixel) + (largeImageSize.height / 2)

        // Calculate crop rect centered on hole
        let cropX = pixelX - (cropSize.width / 2)
        let cropY = pixelY - (cropSize.height / 2)

        // Clamp to image bounds
        let clampedX = max(0, min(cropX, largeImageSize.width - cropSize.width))
        let clampedY = max(0, min(cropY, largeImageSize.height - cropSize.height))

        return CGRect(x: clampedX, y: clampedY, width: cropSize.width, height: cropSize.height)
    }

    private func getLargeImageURL(for courseId: UUID) -> URL {
        let courseCacheURL = cacheDirectory.appendingPathComponent(courseId.uuidString)
        try? FileManager.default.createDirectory(at: courseCacheURL, withIntermediateDirectories: true)
        return courseCacheURL.appendingPathComponent("large_satellite.jpg")
    }

    private func getImageURL(for courseId: UUID, fileName: String) -> URL {
        let courseCacheURL = cacheDirectory.appendingPathComponent(courseId.uuidString)
        try? FileManager.default.createDirectory(at: courseCacheURL, withIntermediateDirectories: true)
        return courseCacheURL.appendingPathComponent(fileName)
    }

    private func createCacheDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
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

    private func updateCacheMetadata(courseId: UUID, largeImageMetadata: LargeSatelliteImageMetadata?, newImages: [SatelliteImageMetadata]?) {
        var allCaches = loadMetadata() ?? []

        if let cacheIndex = allCaches.firstIndex(where: { $0.courseId == courseId }) {
            // Update existing cache
            if let largeImage = largeImageMetadata {
                allCaches[cacheIndex].largeImage = largeImage
            }
            if let images = newImages {
                for newImage in images {
                    if let imageIndex = allCaches[cacheIndex].images.firstIndex(where: { $0.holeNumber == newImage.holeNumber }) {
                        allCaches[cacheIndex].images[imageIndex] = newImage
                    } else {
                        allCaches[cacheIndex].images.append(newImage)
                    }
                }
            }
            allCaches[cacheIndex].lastUpdated = Date()
        } else {
            // Create new cache entry
            let newCache = CourseSatelliteCache(
                courseId: courseId,
                courseName: "",
                largeImage: largeImageMetadata,
                images: newImages ?? []
            )
            allCaches.append(newCache)
        }

        saveMetadata(allCaches)
    }
}
