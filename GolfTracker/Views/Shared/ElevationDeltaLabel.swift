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
/// Hidden when `ElevationReadout` doesn't have enough data (no
/// crossings yet, sparse cells around the query point, test mode).
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
                .foregroundColor(color(for: feet))
                .accessibilityLabel(accessibilityText(feet))
        }
    }

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

    private func color(for feet: Int) -> Color {
        if feet > 0 { return .red.opacity(0.85) }
        if feet < 0 { return .cyan.opacity(0.9) }
        return .white.opacity(0.7)
    }

    private func accessibilityText(_ feet: Int) -> String {
        if feet == 0 { return "Flat to green" }
        return "\(abs(feet)) feet \(feet > 0 ? "uphill" : "downhill") to green"
    }
}
