import SwiftUI
import CoreLocation

/// Compact "↑3" / "↓7" label showing relative elevation in feet to a
/// query point (positive = uphill = target is above you). Default mode
/// tracks the active hole's flag. Pass `coordinate:` to show Δ to a
/// specific point — used by target markers.
///
/// Rounded to the nearest foot. Sub-foot precision is noise from a
/// barometric altimeter; showing decimals would imply more accuracy
/// than the signal supports.
///
/// **No solution renders a dash, not nothing.** Drawing nothing made "the
/// readout has no answer" pixel-identical to "the readout says this hole is
/// flat", because a genuine zero delta prints `↑0` in dim white and a nil
/// prints empty space a glance can't distinguish from it. That ambiguity cost a
/// whole round: on 2026-08-21 the cell map came back truncated and the readout
/// was nil on all nine holes, which was read as a flat course rather than as a
/// broken feature, and the real fault went unnoticed until the round was over.
/// A dash says the feature is alive and has nothing to report; `↑0` says the
/// green is level with you. Those are different facts and now look different.
struct ElevationDeltaLabel: View {
    @ObservedObject private var readout = ElevationReadout.shared

    /// When set, computes Δ to this specific point. When nil, falls
    /// back to the auto-tracked `deltaToGreenMeters` (the active hole's
    /// flag). The flag path is the @Published one — re-renders happen
    /// via the readout. The arbitrary-coordinate path renders whenever
    /// the parent view re-renders (which already happens on path-sample
    /// updates because it observes `readout`).
    var coordinate: CLLocationCoordinate2D?
    var fontSize: CGFloat = 14

    var body: some View {
        if let meters = currentDeltaMeters {
            let feet = Int((meters * 3.28084).rounded())
            Text(formatted(feet))
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundColor(Self.color(forFeet: feet))
                .accessibilityLabel(accessibilityText(feet))
        } else {
            Text(Self.noSolutionGlyph)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundColor(Self.noSolutionColor)
                .accessibilityLabel("Elevation to the green is unavailable")
        }
    }

    /// Deliberately not an arrow and not a digit — it must not be mistakable for
    /// a reading of any magnitude, including zero.
    static let noSolutionGlyph = "–"

    /// Dimmer than flat's `white.opacity(0.7)`, so the two are separable by
    /// weight as well as by shape at a glance on the wrist.
    static let noSolutionColor = Color.white.opacity(0.35)

    private var currentDeltaMeters: Double? {
        if let coordinate {
            return readout.deltaMeters(to: coordinate)
        }
        return readout.deltaToGreenMeters
    }

    /// Up arrow (↑) for non-negative (uphill or flat), down arrow (↓)
    /// for negative (downhill). Magnitude follows the arrow with no
    /// separator: "↑3", "↓7", "↑0".
    private func formatted(_ feet: Int) -> String {
        let arrow = feet >= 0 ? "\u{2191}" : "\u{2193}"
        return "\(arrow)\(abs(feet))"
    }

    /// Uphill red / downhill cyan / flat dim-white. Shared so the watch's
    /// plays-like yardage mode can wear the same color as the delta —
    /// the tint alone signals "adjusted number" and the direction.
    static func color(forFeet feet: Int) -> Color {
        if feet > 0 { return .red.opacity(0.85) }
        if feet < 0 { return .cyan.opacity(0.9) }
        return .white.opacity(0.7)
    }

    private func accessibilityText(_ feet: Int) -> String {
        if feet == 0 { return "Flat to green" }
        return "\(abs(feet)) feet \(feet > 0 ? "uphill" : "downhill") to green"
    }
}

/// Club-trajectory-aware "plays like" math, shared by the display stack
/// (both platforms) and the watch's club predictor.
///
/// Model: Δcarry = Δh / tan(descent angle). A wedge dropping steeply at
/// the target shrugs off elevation; a driver's flat descent feels it
/// most. Angles are the widely published TrackMan PGA Tour averages per
/// club (tour trajectories; amateur flights land a touch shallower, so
/// these under-adjust slightly — tunable against real data later).
enum PlaysLike {
    /// Landing angle (degrees) for a club-type name, parsed loosely so
    /// user-defined names ("7 Iron", "3W", "Sand Wedge") all resolve.
    /// Returns nil for the putter — a rolling ball is different physics
    /// and gets no plays-like number.
    static func descentAngleDegrees(forClubTypeName name: String) -> Double? {
        // Default type names are terse — "Drive", "3-Wood", "4-Hyb",
        // "Pitch", "Gap", "Sand", "Lob", "Putt" — so match on fragments
        // loose enough to also catch user-defined variants.
        let n = name.lowercased()
        if n.contains("putt") { return nil }
        if n.contains("drive") { return 38 }
        if n.contains("hyb") || n.contains("rescue") { return 47 }
        let digit = n.first(where: \.isNumber).flatMap { Int(String($0)) }
        if n.contains("wood") || (n.hasSuffix("w") && digit != nil) {
            switch digit {
            case 3: return 43
            case 5: return 47
            case 7: return 48
            default: return 45
            }
        }
        if n.contains("pitch") || n == "pw" { return 52 }
        if n.contains("gap") || n.contains("approach") || n == "gw" || n == "aw" { return 53 }
        if n.contains("sand") || n == "sw" { return 54 }
        if n.contains("lob") || n == "lw" { return 55 }
        if n.contains("wedge") { return 53 }
        if n.contains("iron") || (n.hasSuffix("i") && digit != nil) {
            switch digit {
            case 2: return 44
            case 3: return 46
            case 4: return 48
            case 5: return 49
            case 6, 7, 8: return 50
            case 9: return 51
            default: return 47
            }
        }
        // Unknown club name: the classic 45° = 1-for-1 baseline.
        return 45
    }

    static func yards(distanceYards: Int, deltaMeters: Double, angleDegrees: Double) -> Int {
        let deltaYards = deltaMeters * 1.09361
        let adjustment = deltaYards / tan(angleDegrees * .pi / 180)
        return distanceYards + Int(adjustment.rounded())
    }

    /// Self-consistent club pick: score each candidate against plays-like
    /// computed with THAT club's own landing angle — "if I hit this club,
    /// does the shot it produces match the shot I need?" No dependence on
    /// the currently selected club, so predictor and display can't
    /// feedback-loop.
    static func bestCandidate<T>(distanceYards: Int,
                                 deltaMeters: Double?,
                                 candidates: [(item: T, typeName: String, averageYards: Int)]) -> T? {
        guard !candidates.isEmpty else { return nil }
        let scored: [(item: T, error: Int)] = candidates.map { c in
            let target: Int
            if let delta = deltaMeters, let angle = descentAngleDegrees(forClubTypeName: c.typeName) {
                target = yards(distanceYards: distanceYards, deltaMeters: delta, angleDegrees: angle)
            } else {
                target = distanceYards
            }
            return (c.item, abs(c.averageYards - target))
        }
        return scored.min { $0.error < $1.error }?.item
    }
}

/// Stacked "plays like" yardage over the elevation delta, sized to sit
/// beside the big yardage readout and together match its height. "≈"
/// marks the adjusted number so it can't be confused with the measured
/// yardage next to it. The adjustment uses the given club's landing
/// angle (see `PlaysLike`).
///
/// Degrades to the bare `ElevationDeltaLabel` when there's no distance
/// or the club is the putter, and renders nothing when the readout has
/// no elevation solution — same disappearing behavior the delta label
/// already has.
struct PlaysLikeStack: View {
    @ObservedObject private var readout = ElevationReadout.shared

    var distanceYards: Int?
    /// Club-type name whose trajectory shapes the adjustment.
    var clubTypeName: String?
    var playsLikeFontSize: CGFloat = 15
    var deltaFontSize: CGFloat = 13

    var body: some View {
        if let dist = distanceYards,
           let meters = readout.deltaToGreenMeters,
           let angle = clubTypeName.flatMap({ PlaysLike.descentAngleDegrees(forClubTypeName: $0) }) {
            let adjusted = PlaysLike.yards(distanceYards: dist, deltaMeters: meters, angleDegrees: angle)
            VStack(alignment: .leading, spacing: 0) {
                Text("\u{2248}\(adjusted)")
                    .font(.system(size: playsLikeFontSize, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.95))
                    .accessibilityLabel("Plays like \(adjusted) yards")
                ElevationDeltaLabel(fontSize: deltaFontSize)
            }
        } else {
            ElevationDeltaLabel(fontSize: deltaFontSize)
        }
    }
}
