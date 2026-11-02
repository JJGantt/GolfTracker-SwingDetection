// The satellite-tile green detector the phone runs when OSM has no greens for
// a course (see CLAUDE.md, "Hole detection (blob analyzer)").
import Foundation
import os
import CoreLocation
import MapKit
import UIKit

struct HoleDetectionRunState {
    var isRunning: Bool
    var message: String
    var progress: Double
    var error: String?
}

/// Every tile failed, so there is nothing to merge. Carries all of the tile
/// errors rather than the first, because which one surfaced was arbitrary and
/// the failure log needs to show what MapKit actually returned.
struct HoleDetectionAllTilesFailed: LocalizedError {
    let errors: [Error]
    var errorDescription: String? { errors.first?.localizedDescription }
}

struct HoleDetectionDiagnostics {
    var tileCount: Int
    var totalGreenPixels: Int
    var totalGreenishPixels: Int
    var totalSwappedChannelExactPixels: Int
    var preMergeBlobCount: Int
    var mergedBlobCount: Int
    var topGreenishColors: [HoleDetectionColorCount]

    var summaryMessage: String {
        "Hole detection ready (\(totalGreenPixels) exact px, \(totalGreenishPixels) greenish px, \(mergedBlobCount) blobs)"
    }
}

struct HoleDetectionAnalyzeResult {
    var data: CourseHoleDetectionData
    var diagnostics: HoleDetectionDiagnostics
}

struct HoleDetectionRGB {
    var r: Int
    var g: Int
    var b: Int

    var formatted: String {
        "\(r),\(g),\(b)"
    }
}

struct HoleDetectionColorCount {
    var color: HoleDetectionRGB
    var count: Int

    var formatted: String {
        "rgb(\(color.formatted))=\(count)"
    }
}

struct HoleDetectionTileResult {
    var blobs: [HoleDetectionBlob]
    var greenPixelCount: Int
    var greenishPixelCount: Int
    var swappedChannelExactCount: Int
    var greenishColorCounts: [UInt32: Int]
}

final class HoleDetectionAnalyzer: Sendable {
    // Exact standard-map green/tee fill from iPhone snapshots.
    private let greenColor = (r: 186, g: 232, b: 153)
    private let sandColor = (r: 245, g: 242, b: 218)
    private let sandTolerance = 10
    /// How far around a blob to look for bunker fill, in METRES. Was a bare
    /// 20-pixel radius, which silently rescaled with `tilePixelSize` — at
    /// 1600 px it meant 25 m, at 1024 px the same constant would have meant
    /// 39 m, quietly widening the search.
    private let sandScanRadiusMeters: Double = 25.0
    private let sandWeight = 1.0
    private let areaWeight = 0.6
    private let widthWeight = 1.0

    private let tileDiameterMeters: Double = 2000.0
    private let tileSpacingMeters: Double = 1800.0
    /// 1024 px over a 2000 m tile ≈ 1.95 m/px. Greens are 20-30 m across, so
    /// this is still ~10 px on the short axis — plenty to segment. Was 1600
    /// (1.25 m/px), which cost 2.4× the pixels for resolution we never used.
    private let tilePixelSize = 1024
    /// Tiles fetched and scanned at once. They're independent, so the old
    /// sequential loop was pure wall-clock waste — 9 snapshots at ~1.2 s each
    /// was essentially the whole 13 s run. At 1024 px each tile holds ~4 MB of
    /// pixels plus its CGImage, so all 9 in flight is ~75 MB peak; at the old
    /// 1600 px this would have been ~180 MB and genuinely risky on older
    /// hardware. MapKit may still throttle internally — `snapshotStandardMap`
    /// retries on `MKError.loadingThrottled` rather than failing the tile.
    private let maxConcurrentTiles = 9
    private let duplicateDistanceMeters: Double = 18.0
    /// Smallest blob we'll accept, in SQUARE METRES. Physical rather than a
    /// pixel count so `tilePixelSize` can change without re-tuning the filter:
    /// the old bare `20` meant 31 m² at 1600 px but would have meant 76 m² at
    /// 1024 px, tripling the rejection floor as a side effect of a perf tweak.
    /// A real green is 400-700 m², so this only ever rejects speckle.
    private let minimumBlobAreaSquareMeters: Double = 31.0
    private let maxPolygonPoints = 24
    private let diagnosticsTopColorLimit = 10
    private let diagnosticsColorCountThreshold = 1000

    /// Ground resolution of one tile pixel.
    private var metersPerPixel: Double { tileDiameterMeters / Double(tilePixelSize) }
    /// The physical thresholds above, converted to pixels for the scan.
    private var minimumRawArea: Int {
        max(1, Int((minimumBlobAreaSquareMeters / (metersPerPixel * metersPerPixel)).rounded()))
    }
    private var sandScanRadius: Int {
        max(1, Int((sandScanRadiusMeters / metersPerPixel).rounded()))
    }

    func detect(
        courseId: UUID,
        center: CLLocationCoordinate2D,
        coverageRadiusMeters: Double,
        boundingPolygons: [[CLLocationCoordinate2D]]? = nil,
        progress: @escaping @Sendable (String, Double) -> Void,
        completion: @escaping @Sendable (Result<HoleDetectionAnalyzeResult, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let allTiles = self.buildTileCenters(center: center, coverageRadiusMeters: coverageRadiusMeters)
                // Skip tiles that can't contribute. A blob whose centroid falls
                // outside every bounding polygon is discarded after the merge
                // anyway (see the polygon gate below), so a tile with no
                // polygon overlap only ever produces rejects. This needs no
                // more trust in OSM outlines than the existing output gate
                // already places in them, and the test is bounding-box based,
                // so any partial overlap keeps the tile.
                let tileCenters = self.tilesOverlapping(allTiles, polygons: boundingPolygons)
                let skipped = allTiles.count - tileCenters.count

                var blobs: [HoleDetectionBlob] = []
                let totalTiles = max(tileCenters.count, 1)
                var totalGreenPixels = 0
                var totalGreenishPixels = 0
                var totalSwappedChannelExactPixels = 0
                var mergedGreenishColorCounts: [UInt32: Int] = [:]

                // Tiles are independent, so fetch and scan them concurrently.
                // `snapshotStandardMap` blocks its thread on a semaphore while
                // MapKit renders on the main queue, which is why doing these
                // one at a time cost the entire run.
                let limiter = DispatchSemaphore(value: self.maxConcurrentTiles)
                let group = DispatchGroup()
                struct Collected {
                    var results: [Int: HoleDetectionTileResult] = [:]
                    var errors: [Error] = []
                    var completed = 0
                }
                let collected = OSAllocatedUnfairLock(initialState: Collected())

                if skipped > 0 {
                    progress("Scanning \(tileCenters.count) map tiles (\(skipped) outside course)...", 0.02)
                } else {
                    progress("Scanning \(tileCenters.count) map tiles...", 0.02)
                }

                for (index, tileCenter) in tileCenters.enumerated() {
                    limiter.wait()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { limiter.signal(); group.leave() }
                        do {
                            let snapshotImage = try self.snapshotStandardMap(center: tileCenter)
                            let result = self.detectBlobs(
                                in: snapshotImage,
                                tileCenter: tileCenter,
                                tileDiameterMeters: self.tileDiameterMeters
                            )
                            let done = collected.withLock { c in
                                c.results[index] = result
                                c.completed += 1
                                return c.completed
                            }
                            progress("Scanned \(done)/\(totalTiles) tiles...",
                                     min(0.02 + 0.9 * Double(done) / Double(totalTiles), 0.94))
                        } catch {
                            collected.withLock { $0.errors.append(error); $0.completed += 1 }
                        }
                    }
                }
                group.wait()
                let (tileResults, tileErrors) = collected.withLock { ($0.results, $0.errors) }

                // A tile that failed shouldn't sink the whole course — partial
                // coverage still places most greens. Only give up when nothing
                // came back at all.
                if tileResults.isEmpty, !tileErrors.isEmpty {
                    throw HoleDetectionAllTilesFailed(errors: tileErrors)
                }

                // Merge in tile order so the output is deterministic regardless
                // of which tile finished first.
                for index in tileCenters.indices {
                    guard let tileResult = tileResults[index] else { continue }
                    blobs.append(contentsOf: tileResult.blobs)
                    totalGreenPixels += tileResult.greenPixelCount
                    totalGreenishPixels += tileResult.greenishPixelCount
                    totalSwappedChannelExactPixels += tileResult.swappedChannelExactCount
                    for (color, count) in tileResult.greenishColorCounts {
                        mergedGreenishColorCounts[color, default: 0] += count
                    }
                }

                progress("Merging overlaps...", 0.95)
                let mergedBlobs = self.mergeDuplicateBlobs(blobs)

                // Polygon gate: when the OSM relation gave us a course
                // outline, drop any merged blob whose centroid sits
                // outside ALL of the bounding polygons. Multiple polygons
                // = canonical + sibling-relation outlines unioned (e.g.
                // courses with two competing OSM features for the same
                // physical course). When boundingPolygons is nil we fall
                // back to the radius-only behaviour.
                let scopedBlobs: [HoleDetectionBlob] = {
                    guard let polys = boundingPolygons, !polys.isEmpty else { return mergedBlobs }
                    return mergedBlobs.filter { blob in
                        let pt = CLLocationCoordinate2D(latitude: blob.centroidLatitude, longitude: blob.centroidLongitude)
                        return polys.contains { Self.pointInPolygon(pt, polygon: $0) }
                    }
                }()

                let data = CourseHoleDetectionData(
                    courseId: courseId,
                    generatedAt: Date(),
                    blobs: scopedBlobs
                )
                let topGreenishColors = mergedGreenishColorCounts
                    .filter { $0.value >= self.diagnosticsColorCountThreshold }
                    .sorted {
                        if $0.value == $1.value { return $0.key < $1.key }
                        return $0.value > $1.value
                    }
                    .prefix(self.diagnosticsTopColorLimit)
                    .map {
                        HoleDetectionColorCount(
                            color: self.unpackRGB($0.key),
                            count: $0.value
                        )
                    }

                let diagnostics = HoleDetectionDiagnostics(
                    tileCount: tileCenters.count,
                    totalGreenPixels: totalGreenPixels,
                    totalGreenishPixels: totalGreenishPixels,
                    totalSwappedChannelExactPixels: totalSwappedChannelExactPixels,
                    preMergeBlobCount: blobs.count,
                    mergedBlobCount: scopedBlobs.count,
                    topGreenishColors: topGreenishColors
                )

                progress(diagnostics.summaryMessage, 1.0)
                completion(.success(HoleDetectionAnalyzeResult(
                    data: data,
                    diagnostics: diagnostics
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Drop tiles whose footprint doesn't overlap any course outline.
    ///
    /// Bounding-box test on both sides, deliberately conservative: a tile that
    /// clips a polygon at all is kept. Returns every tile unchanged when we
    /// have no outlines, preserving the radius-only behaviour.
    private func tilesOverlapping(_ tiles: [CLLocationCoordinate2D],
                                  polygons: [[CLLocationCoordinate2D]]?) -> [CLLocationCoordinate2D] {
        guard let polygons = polygons, !polygons.isEmpty else { return tiles }

        // Half a tile, in degrees, at this latitude.
        let halfLat = (tileDiameterMeters / 2) / 111_000.0
        var boxes: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)] = []
        for poly in polygons where !poly.isEmpty {
            boxes.append((poly.map(\.latitude).min()!, poly.map(\.latitude).max()!,
                          poly.map(\.longitude).min()!, poly.map(\.longitude).max()!))
        }
        guard !boxes.isEmpty else { return tiles }

        let kept = tiles.filter { tile in
            let halfLon = (tileDiameterMeters / 2) /
                (111_000.0 * max(cos(tile.latitude * .pi / 180), 0.01))
            let tMinLat = tile.latitude - halfLat, tMaxLat = tile.latitude + halfLat
            let tMinLon = tile.longitude - halfLon, tMaxLon = tile.longitude + halfLon
            return boxes.contains { b in
                tMinLat <= b.maxLat && tMaxLat >= b.minLat &&
                tMinLon <= b.maxLon && tMaxLon >= b.minLon
            }
        }
        // Never return nothing — a bad outline shouldn't silently disable
        // detection for the whole course.
        return kept.isEmpty ? tiles : kept
    }

    private func buildTileCenters(center: CLLocationCoordinate2D, coverageRadiusMeters: Double) -> [CLLocationCoordinate2D] {
        let tileRadius = tileDiameterMeters / 2
        let neededSteps = Int(ceil(max(0, coverageRadiusMeters - tileRadius) / tileSpacingMeters))
        let stepCount = max(1, min(2, neededSteps))

        var centers: [CLLocationCoordinate2D] = []
        for y in (-stepCount)...stepCount {
            for x in (-stepCount)...stepCount {
                let northMeters = Double(y) * tileSpacingMeters
                let eastMeters = Double(x) * tileSpacingMeters
                centers.append(offsetCoordinate(from: center, northMeters: northMeters, eastMeters: eastMeters))
            }
        }
        return centers
    }

    /// One tile, with retry. MapKit rate-limits tile loading, and running the
    /// tiles concurrently makes `MKError.loadingThrottled` likely rather than
    /// theoretical — retrying with backoff is cheaper than serialising
    /// everything to avoid it.
    private func snapshotStandardMap(center: CLLocationCoordinate2D) throws -> CGImage {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try snapshotStandardMapOnce(center: center)
            } catch {
                lastError = error
                let isThrottle = (error as NSError).domain == MKErrorDomain
                    && (error as NSError).code == MKError.loadingThrottled.rawValue
                guard isThrottle, attempt < 2 else { throw error }
                Thread.sleep(forTimeInterval: 0.6 * Double(attempt + 1))
            }
        }
        throw lastError ?? NSError(domain: "HoleDetectionAnalyzer", code: -2,
                                   userInfo: [NSLocalizedDescriptionKey: "Map snapshot failed"])
    }

    private func snapshotStandardMapOnce(center: CLLocationCoordinate2D) throws -> CGImage {
        let semaphore = DispatchSemaphore(value: 0)
        // Written on main by the completion, read here after the semaphore
        // (or after a timeout, when the completion may still be running).
        let outcome = OSAllocatedUnfairLock<(image: CGImage?, error: Error?)>(initialState: (nil, nil))
        let diameter = tileDiameterMeters
        let pixels = tilePixelSize

        // MKMapSnapshotter (and the trait collection it is given) must be
        // created and started on the main thread. The completion handler is
        // also delivered on main, which is fine since we only block the
        // background thread with the semaphore.
        DispatchQueue.main.async {
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: diameter,
                longitudinalMeters: diameter
            )
            options.size = CGSize(width: pixels, height: pixels)
            options.mapType = .standard
            options.showsBuildings = false
            options.pointOfInterestFilter = .excludingAll
            // Force light mode and 1x scale so the green fill color (186,232,153) matches
            // regardless of the device's appearance setting or display scale.
            options.traitCollection = UITraitCollection { traits in
                traits.userInterfaceStyle = .light
                traits.displayScale = 1.0
            }
            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { snapshot, error in
                let image = snapshot?.image.cgImage
                outcome.withLock { $0 = (error == nil ? image : nil, error) }
                semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            throw NSError(
                domain: "HoleDetectionAnalyzer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Map snapshot timed out"]
            )
        }

        let (capturedImage, capturedError) = outcome.withLock { $0 }
        if let error = capturedError {
            throw error
        }

        guard let image = capturedImage else {
            throw NSError(
                domain: "HoleDetectionAnalyzer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No map snapshot image returned"]
            )
        }

        return image
    }

    private func detectBlobs(
        in image: CGImage,
        tileCenter: CLLocationCoordinate2D,
        tileDiameterMeters: Double
    ) -> HoleDetectionTileResult {
        let width = image.width
        let height = image.height
        let pixelCount = width * height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: pixelCount * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return HoleDetectionTileResult(
                blobs: [],
                greenPixelCount: 0,
                greenishPixelCount: 0,
                swappedChannelExactCount: 0,
                greenishColorCounts: [:]
            )
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var isGreen = [Bool](repeating: false, count: pixelCount)
        var greenPixelCount = 0
        var greenishPixelCount = 0
        var swappedChannelExactCount = 0
        var greenishColorCounts: [UInt32: Int] = [:]
        for idx in 0..<pixelCount {
            let offset = idx * 4
            let r = Int(pixelData[offset])
            let g = Int(pixelData[offset + 1])
            let b = Int(pixelData[offset + 2])
            let isGreenPixel = (r == greenColor.r && g == greenColor.g && b == greenColor.b)
            isGreen[idx] = isGreenPixel
            if isGreenPixel {
                greenPixelCount += 1
            }
            if b == greenColor.r && g == greenColor.g && r == greenColor.b {
                swappedChannelExactCount += 1
            }
            if g >= 90 && g > r + 8 && g > b + 8 {
                greenishPixelCount += 1
                let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                greenishColorCounts[key, default: 0] += 1
            }
        }

        var visited = [Bool](repeating: false, count: pixelCount)
        let metersPerPixel = tileDiameterMeters / Double(width)
        var detected: [HoleDetectionBlob] = []

        for start in 0..<pixelCount {
            if !isGreen[start] || visited[start] { continue }

            var queue: [Int] = [start]
            visited[start] = true
            var queueIndex = 0

            var area = 0
            var sumX = 0
            var sumY = 0
            var minX = Int.max
            var maxX = Int.min
            var minY = Int.max
            var maxY = Int.min
            var boundaryPoints: [(x: Int, y: Int)] = []

            while queueIndex < queue.count {
                let current = queue[queueIndex]
                queueIndex += 1

                let x = current % width
                let y = current / width

                area += 1
                sumX += x
                sumY += y
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                var isBoundaryPixel = false
                let neighbors = [
                    (x: x + 1, y: y),
                    (x: x - 1, y: y),
                    (x: x, y: y + 1),
                    (x: x, y: y - 1)
                ]

                for n in neighbors {
                    guard n.x >= 0, n.x < width, n.y >= 0, n.y < height else {
                        isBoundaryPixel = true
                        continue
                    }

                    let nIdx = n.y * width + n.x
                    if !isGreen[nIdx] {
                        isBoundaryPixel = true
                        continue
                    }

                    if !visited[nIdx] {
                        visited[nIdx] = true
                        queue.append(nIdx)
                    }
                }

                if isBoundaryPixel {
                    boundaryPoints.append((x: x, y: y))
                }
            }

            if area < minimumRawArea { continue }

            let blobWidth = max(1, maxX - minX + 1)
            let blobHeight = max(1, maxY - minY + 1)
            let minWidth = Double(min(blobWidth, blobHeight))
            let maxWidth = Double(max(blobWidth, blobHeight))
            let elongation = maxWidth / max(minWidth, 1.0)
            let centroidX = Double(sumX) / Double(area)
            let centroidY = Double(sumY) / Double(area)

            // Sand-surround percentage replaces the old "raw count of sand
            // pixels in bounding-box-extended-by-radius" metric. The new
            // metric is: cast 72 rays from the centroid, walk past the
            // blob's own green pixels, then walk 10 yd outward; record the
            // fraction of rays that hit any sand pixel within that window.
            // Rewards greens RINGED by bunkers (the diagnostic geometry of
            // a real green) without rewarding a single huge bunker on one
            // side. Mirrors the algorithm proven out in HoleDetect.
            let sandSurroundPct = computeSandSurroundFraction(
                centroidX: centroidX,
                centroidY: centroidY,
                isGreen: isGreen,
                pixelData: pixelData,
                width: width,
                height: height,
                metersPerPixel: metersPerPixel
            )

            let greenness = calculateGreennessScore(
                area: area,
                minWidth: minWidth,
                elongation: elongation,
                sandSurroundPct: sandSurroundPct
            )

            let hull = convexHull(points: boundaryPoints)
            let reducedHull = reducePoints(hull, maxPoints: maxPolygonPoints)
            let polygonPoints: [MapPoint]
            if reducedHull.count >= 3 {
                polygonPoints = reducedHull.map {
                    MapPoint(pixelToCoordinate(
                        x: Double($0.x),
                        y: Double($0.y),
                        tileCenter: tileCenter,
                        imageWidth: Double(width),
                        imageHeight: Double(height),
                        metersPerPixel: metersPerPixel
                    ))
                }
            } else {
                // Fall back to a small box around centroid if hull is too small.
                let halfSize = 2.0
                let fallbackPixels = [
                    (centroidX - halfSize, centroidY - halfSize),
                    (centroidX + halfSize, centroidY - halfSize),
                    (centroidX + halfSize, centroidY + halfSize),
                    (centroidX - halfSize, centroidY + halfSize)
                ]
                polygonPoints = fallbackPixels.map {
                    MapPoint(pixelToCoordinate(
                        x: $0.0,
                        y: $0.1,
                        tileCenter: tileCenter,
                        imageWidth: Double(width),
                        imageHeight: Double(height),
                        metersPerPixel: metersPerPixel
                    ))
                }
            }

            let centroidCoordinate = pixelToCoordinate(
                x: centroidX,
                y: centroidY,
                tileCenter: tileCenter,
                imageWidth: Double(width),
                imageHeight: Double(height),
                metersPerPixel: metersPerPixel
            )

            detected.append(HoleDetectionBlob(
                area: area,
                minWidth: minWidth,
                elongation: elongation,
                greennessScore: greenness,
                centroidLatitude: centroidCoordinate.latitude,
                centroidLongitude: centroidCoordinate.longitude,
                polygon: polygonPoints
            ))
        }

        return HoleDetectionTileResult(
            blobs: detected,
            greenPixelCount: greenPixelCount,
            greenishPixelCount: greenishPixelCount,
            swappedChannelExactCount: swappedChannelExactCount,
            greenishColorCounts: greenishColorCounts
        )
    }

    private func unpackRGB(_ key: UInt32) -> HoleDetectionRGB {
        HoleDetectionRGB(
            r: Int((key >> 16) & 0xFF),
            g: Int((key >> 8) & 0xFF),
            b: Int(key & 0xFF)
        )
    }

    /// Sand-surround percentage for a single blob — the angular-coverage
    /// metric proven out in HoleDetect. Casts `sandSurroundRays` rays from
    /// the centroid (every 5° by default), walks past the blob's own green
    /// pixels (using the precomputed `isGreen` mask — no color-matching
    /// needed), then walks `sandSurroundDistanceYards` outward; records
    /// the fraction of rays that hit any sand pixel within that window.
    /// Returns a value in [0, 100] (1-decimal).
    private func computeSandSurroundFraction(
        centroidX: Double,
        centroidY: Double,
        isGreen: [Bool],
        pixelData: [UInt8],
        width: Int,
        height: Int,
        metersPerPixel: Double
    ) -> Double {
        let rayCount = 72
        let distanceYards = 10.0
        let yardsPerMeter = 1.09361
        let metersPerYard = 1.0 / yardsPerMeter
        let outwardSteps = max(1, Int(((distanceYards * metersPerYard) / metersPerPixel).rounded()))
        let maxBlobSkip = 200

        @inline(__always)
        func pxIsGreen(_ x: Int, _ y: Int) -> Bool {
            if x < 0 || x >= width || y < 0 || y >= height { return false }
            return isGreen[y * width + x]
        }

        @inline(__always)
        func pxIsSand(_ x: Int, _ y: Int) -> Bool {
            if x < 0 || x >= width || y < 0 || y >= height { return false }
            let o = (y * width + x) * 4
            let r = Int(pixelData[o]), g = Int(pixelData[o + 1]), b = Int(pixelData[o + 2])
            return abs(r - sandColor.r) <= sandTolerance
                && abs(g - sandColor.g) <= sandTolerance
                && abs(b - sandColor.b) <= sandTolerance
        }

        var hits = 0
        for i in 0..<rayCount {
            let angle = Double(i) / Double(rayCount) * 2.0 * .pi
            let dx = cos(angle)
            let dy = sin(angle)
            // Walk past in-blob green pixels first (radial exit through perimeter)
            var step = 0
            while step < maxBlobSkip {
                let x = Int((centroidX + dx * Double(step)).rounded())
                let y = Int((centroidY + dy * Double(step)).rounded())
                if !pxIsGreen(x, y) { break }
                step += 1
            }
            // Then walk outward checking for sand
            var rayHit = false
            for k in 0...outwardSteps {
                let x = Int((centroidX + dx * Double(step + k)).rounded())
                let y = Int((centroidY + dy * Double(step + k)).rounded())
                if pxIsSand(x, y) { rayHit = true; break }
            }
            if rayHit { hits += 1 }
        }
        let pct = Double(hits) / Double(rayCount) * 1000.0
        return (pct.rounded()) / 10.0
    }

    /// Greenness score: shape-only base, then multiplied by sand-surround %
    /// when > 1 (no penalty for unbunkered greens). Mirrors the formula in
    /// HoleDetect's `calculateGreennessScore`.
    private func calculateGreennessScore(area: Int, minWidth: Double, elongation: Double, sandSurroundPct: Double) -> Int {
        let areaContrib = Double(area) * areaWeight
        let widthContrib = minWidth * widthWeight
        let elongationPenalty = max(elongation * elongation, 1.0e-6)
        let base = (areaContrib + widthContrib) / elongationPenalty
        let multiplier = sandSurroundPct > 1.0 ? sandSurroundPct : 1.0
        return Int((base * multiplier).rounded())
    }

    /// Standard ray-casting point-in-polygon. Used by the bounding-polygon
    /// gate to drop blobs detected on neighboring courses. Same algorithm
    /// as `HoleDetectionBlob.contains` — duplicated as a static here to
    /// avoid leaking analyzer concerns into the model layer.
    static func pointInPolygon(_ pt: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        let x = pt.longitude, y = pt.latitude
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            if (yi > y) != (yj > y) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private func mergeDuplicateBlobs(_ blobs: [HoleDetectionBlob]) -> [HoleDetectionBlob] {
        let sorted = blobs.sorted {
            if $0.greennessScore == $1.greennessScore {
                return $0.area > $1.area
            }
            return $0.greennessScore > $1.greennessScore
        }

        var merged: [HoleDetectionBlob] = []
        for blob in sorted {
            if let matchIndex = merged.firstIndex(where: {
                distanceMeters(
                    CLLocationCoordinate2D(latitude: $0.centroidLatitude, longitude: $0.centroidLongitude),
                    CLLocationCoordinate2D(latitude: blob.centroidLatitude, longitude: blob.centroidLongitude)
                ) < duplicateDistanceMeters
            }) {
                let existing = merged[matchIndex]
                if blob.greennessScore > existing.greennessScore ||
                    (blob.greennessScore == existing.greennessScore && blob.area > existing.area) {
                    merged[matchIndex] = blob
                }
            } else {
                merged.append(blob)
            }
        }
        return merged
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return aLoc.distance(from: bLoc)
    }

    private func pixelToCoordinate(
        x: Double,
        y: Double,
        tileCenter: CLLocationCoordinate2D,
        imageWidth: Double,
        imageHeight: Double,
        metersPerPixel: Double
    ) -> CLLocationCoordinate2D {
        let pixelOffsetX = x - (imageWidth / 2.0)
        let pixelOffsetY = y - (imageHeight / 2.0)

        let metersEast = pixelOffsetX * metersPerPixel
        let metersNorth = -pixelOffsetY * metersPerPixel

        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(tileCenter.latitude * .pi / 180.0)

        return CLLocationCoordinate2D(
            latitude: tileCenter.latitude + (metersNorth / metersPerDegreeLat),
            longitude: tileCenter.longitude + (metersEast / metersPerDegreeLon)
        )
    }

    private func offsetCoordinate(from coordinate: CLLocationCoordinate2D, northMeters: Double, eastMeters: Double) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(coordinate.latitude * .pi / 180.0)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + (northMeters / metersPerDegreeLat),
            longitude: coordinate.longitude + (eastMeters / metersPerDegreeLon)
        )
    }

    private func convexHull(points: [(x: Int, y: Int)]) -> [(x: Int, y: Int)] {
        guard points.count >= 3 else { return points }

        let sorted = points.sorted { lhs, rhs in
            lhs.x < rhs.x || (lhs.x == rhs.x && lhs.y < rhs.y)
        }

        func cross(_ a: (x: Int, y: Int), _ b: (x: Int, y: Int), _ c: (x: Int, y: Int)) -> Int {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        var lower: [(x: Int, y: Int)] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                _ = lower.popLast()
            }
            lower.append(point)
        }

        var upper: [(x: Int, y: Int)] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                _ = upper.popLast()
            }
            upper.append(point)
        }

        _ = lower.popLast()
        _ = upper.popLast()
        return lower + upper
    }

    private func reducePoints(_ points: [(x: Int, y: Int)], maxPoints: Int) -> [(x: Int, y: Int)] {
        guard points.count > maxPoints, maxPoints > 2 else { return points }
        var reduced: [(x: Int, y: Int)] = []
        let step = Double(points.count) / Double(maxPoints)
        for i in 0..<maxPoints {
            let index = min(points.count - 1, Int((Double(i) * step).rounded(.down)))
            reduced.append(points[index])
        }
        return reduced
    }
}
