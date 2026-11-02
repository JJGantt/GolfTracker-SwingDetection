import Foundation

/// The green candidates a course offers, in the order both devices show them.
enum GreenCandidates {

    /// The course's OSM green polygons first, as blobs that pass every filter
    /// (they are mapped greens, not guesses), then the detector's blobs that
    /// pass the user's filter settings.
    static func list(osmGreens: [[MapPoint]]?,
                     detection: CourseHoleDetectionData?,
                     filter: HoleDetectionFilterSettings) -> [HoleDetectionBlob] {
        var out = (osmGreens ?? []).map(blob(fromOSMGreen:))
        if let detection {
            out.append(contentsOf: filter.apply(to: detection.blobs))
        }
        return out
    }

    /// An OSM green as a blob: its vertex-average centre and scores high
    /// enough that no filter drops it. The id is synthetic, since OSM way ids
    /// are Int64.
    static func blob(fromOSMGreen points: [MapPoint]) -> HoleDetectionBlob {
        let n = Double(max(points.count, 1))
        return HoleDetectionBlob(
            id: UUID(),
            area: 9_999,
            minWidth: 999,
            elongation: 1.0,
            greennessScore: 9_999,
            centroidLatitude: points.map(\.latitude).reduce(0, +) / n,
            centroidLongitude: points.map(\.longitude).reduce(0, +) / n,
            polygon: points
        )
    }
}
