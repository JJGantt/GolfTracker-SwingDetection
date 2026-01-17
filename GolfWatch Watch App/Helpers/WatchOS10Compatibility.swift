#if os(watchOS)
import SwiftUI
import MapKit

// MARK: - watchOS 10 Compatibility Helpers

/// Hides map controls on watchOS 11+, disables map on watchOS 10 when not interactive
struct HideMapControlsModifier: ViewModifier {
    let isInteractive: Bool

    init(isInteractive: Bool = false) {
        self.isInteractive = isInteractive
    }

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content
                .mapControls {}
                .mapControlVisibility(.hidden)
        } else {
            // On watchOS 10, disable the map when not interactive
            // to prevent its built-in controls from capturing crown input
            content.disabled(!isInteractive)
        }
    }
}

/// Digital crown rotation for club selection with sensitivity on watchOS 11+
struct ClubCrownRotationModifier: ViewModifier {
    @Binding var selectedClubIndex: Double
    let clubCount: Int

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.digitalCrownRotation(
                $selectedClubIndex,
                from: 0,
                through: Double(max(clubCount - 1, 0)),
                by: 1,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
        } else {
            content.digitalCrownRotation(
                $selectedClubIndex,
                from: 0,
                through: Double(max(clubCount - 1, 0)),
                by: 1,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
        }
    }
}

/// Digital crown rotation for distance editing with sensitivity on watchOS 11+
struct DistanceCrownRotationModifier: ViewModifier {
    @Binding var distance: Double

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.digitalCrownRotation(
                $distance,
                from: 10,
                through: 350,
                by: 1,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
        } else {
            content.digitalCrownRotation(
                $distance,
                from: 10,
                through: 350,
                by: 1,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
        }
    }
}

/// Digital crown rotation for zoom control with sensitivity on watchOS 11+
struct ZoomCrownRotationModifier: ViewModifier {
    @Binding var scale: CGFloat

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.digitalCrownRotation(
                $scale,
                from: 0.5,
                through: 3.0,
                by: 0.05,
                sensitivity: .medium,
                isContinuous: true,
                isHapticFeedbackEnabled: true
            )
        } else {
            content.digitalCrownRotation(
                $scale,
                from: 0.5,
                through: 3.0,
                by: 0.05,
                isContinuous: true,
                isHapticFeedbackEnabled: true
            )
        }
    }
}

/// Applies hand gesture shortcut on watchOS 11+, no-op on watchOS 10
struct HandGestureShortcutModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}

/// Bottom padding for action buttons - less padding on watchOS 10 to move buttons closer to screen edge
struct ButtonsBottomPaddingModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.padding(.bottom, 16)
        } else {
            // On watchOS 10, use minimal padding to push buttons to bottom
            content.padding(.bottom, 12)
        }
    }
}
#endif
