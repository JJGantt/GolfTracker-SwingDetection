import SwiftUI
import MapKit
import WatchKit

struct ActiveRoundView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var locationManager = LocationManager.shared
    @StateObject private var swingDetector = SwingDetectionManager.shared
    @StateObject private var workoutManager = WorkoutManager.shared
    @StateObject private var satelliteCache = WatchSatelliteCacheManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var selectedClubIndex: Double = 0
    @State private var position: MapCameraPosition = .automatic
    @State private var showingRecordedFeedback = false
    @State private var crownOffset: CGFloat = 0
    @State private var isPlacingTarget = false
    @State private var isPlacingPenalty = false
    @State private var temporaryPenaltyPosition: CLLocationCoordinate2D?
    @State private var showingActionsSheet = false
    @State private var showingEditHole = false
    @State private var showingAddHole = false
    @State private var navigateToAddHole = false
    @State private var isLastStrokeViewMode = false
    @State private var undoHoldProgress: Double = 0.0
    @State private var undoHoldTimer: Timer?
    @State private var isPlacingHole = false
    @State private var temporaryHolePosition: CLLocationCoordinate2D?
    @State private var isFullViewMode = false
    @State private var isCrownScrolling = false
    @State private var crownScrollTimer: Timer?
    @State private var isPulsing = false
    @State private var showingUndoConfirmation = false
    @State private var showingDistanceEditor = false
    @State private var manualClubOverride = false       // True when user manually changed club
    @State private var isAutoSelectingClub = false      // True when we're programmatically updating club
    @FocusState private var isMapFocused: Bool
    @FocusState private var isMainViewFocused: Bool

    private var clubs: [ClubData] {
        return store.availableClubs
    }

    private var selectedClub: ClubData? {
        guard !clubs.isEmpty else { return nil }
        let index = Int(selectedClubIndex.rounded()) % clubs.count
        return clubs[index]
    }

    private var canUndo: Bool {
        guard let hole = store.currentHole else { return false }

        // Can undo if current hole is finished
        if store.isHoleCompleted(hole.number) {
            return true
        }

        // Can undo if there are strokes on current hole
        let strokesForHole = store.currentRound?.strokes.filter { $0.holeNumber == hole.number } ?? []
        if !strokesForHole.isEmpty {
            return true
        }

        // Can undo if we just finished the previous hole (no strokes on current, previous is completed)
        if store.currentHoleIndex > 0,
           let round = store.currentRound,
           let course = store.getCourse(for: round) {
            let previousHoleNumber = course.holes[store.currentHoleIndex - 1].number
            return round.isHoleCompleted(previousHoleNumber)
        }

        return false
    }

    private var distanceToHole: Int? {
        print("⌚ [Distance] locationManager.location: \(locationManager.location?.description ?? "nil")")
        print("⌚ [Distance] currentHole: \(store.currentHole?.number.description ?? "nil")")

        guard let userLocation = locationManager.location,
              let hole = store.currentHole else {
            print("⌚ [Distance] Returning nil - missing location or hole")
            return nil
        }

        let holeLocation = CLLocation(
            latitude: hole.coordinate.latitude,
            longitude: hole.coordinate.longitude
        )

        let distanceInMeters = userLocation.distance(from: holeLocation)
        let yards = Int(distanceInMeters * 1.09361)
        print("⌚ [Distance] Calculated distance: \(yards) yards")
        return yards
    }

    private var lastRealStroke: Stroke? {
        guard let round = store.currentRound,
              let hole = store.currentHole else { return nil }

        let strokesForHole = round.strokes
            .filter { $0.holeNumber == hole.number && !$0.isPenalty }
            .sorted { $0.strokeNumber > $1.strokeNumber }

        return strokesForHole.first
    }

    private var firstStroke: Stroke? {
        guard let round = store.currentRound else { return nil }

        // Determine hole number
        let holeNumber: Int
        if let hole = store.currentHole {
            holeNumber = hole.number
        } else {
            let course = store.getCourse(for: round)
            holeNumber = (course?.holes.count ?? 0) + 1
        }

        let strokesForHole = round.strokes
            .filter { $0.holeNumber == holeNumber }
            .sorted { $0.strokeNumber < $1.strokeNumber }

        return strokesForHole.first
    }

    private var targetCoordinatesBinding: Binding<[CLLocationCoordinate2D]> {
        Binding(
            get: {
                guard let round = self.store.currentRound,
                      let hole = self.store.currentHole else { return [] }
                return round.targets
                    .filter { $0.holeNumber == hole.number }
                    .map { $0.coordinate }
            },
            set: { newCoordinates in
                guard var round = self.store.currentRound,
                      let hole = self.store.currentHole else { return }

                // Remove old targets for this hole
                round.targets.removeAll { $0.holeNumber == hole.number }

                // Add new targets
                let newTargets = newCoordinates.map { Target(holeNumber: hole.number, coordinate: $0) }
                round.targets.append(contentsOf: newTargets)

                // Update in store
                self.store.currentRound = round
                self.store.saveToStorage()

                // Sync to iPhone
                WatchConnectivityManager.shared.sendRound(round)
            }
        )
    }

    private func distanceToTarget(_ target: CLLocationCoordinate2D) -> Int? {
        guard let userLocation = locationManager.location else { return nil }

        let targetLocation = CLLocation(
            latitude: target.latitude,
            longitude: target.longitude
        )

        let distanceInMeters = userLocation.distance(from: targetLocation)
        return Int(distanceInMeters * 1.09361) // Convert to yards
    }

    // Calculate the rotation angle for the aim arrow
    @ViewBuilder
    private func clubSelectorOverlay(clubFontSize: CGFloat) -> some View {
        // Guard against empty clubs array to prevent division by zero
        if clubs.isEmpty {
            Text("No Clubs")
                .font(.system(size: clubFontSize, weight: .semibold))
                .foregroundColor(.white)
        } else {
            // Get surrounding clubs
            let currentIndex = Int(selectedClubIndex.rounded()) % clubs.count
            let previous2Index = (currentIndex - 2 + clubs.count) % clubs.count
            let previous1Index = (currentIndex - 1 + clubs.count) % clubs.count
            let next1Index = (currentIndex + 1) % clubs.count
            let next2Index = (currentIndex + 2) % clubs.count

            let previous2Club = clubs[previous2Index]
            let previous1Club = clubs[previous1Index]
            let next1Club = clubs[next1Index]
            let next2Club = clubs[next2Index]

            let currentSize = isCrownScrolling ? clubFontSize * 1.3 : clubFontSize
            let adjacent1Size = clubFontSize * 0.8  // Directly adjacent clubs (bigger)
            let adjacent2Size = clubFontSize * 0.65 // Further clubs (smaller)

        // Calculate spacing based on actual text height (approximate)
        let adjacent1Height: CGFloat = adjacent1Size + 8  // Increased spacing for directly adjacent
        let adjacent2Height: CGFloat = adjacent2Size + 4

        VStack {
            Spacer()
                .frame(height: crownOffset)
            HStack {
                Spacer()

                ZStack {
                    // Current club - stays in the same position
                    Text(selectedClub.map { store.getTypeName(for: $0) } ?? "No Club")
                        .font(.system(size: currentSize, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.ultraThinMaterial)
                                .opacity(0.9)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                    // Two clubs above when scrolling (only if not at top)
                    if isCrownScrolling {
                        // Previous -1 (directly above current) - only show if currentIndex >= 1
                        if currentIndex >= 1 {
                            Text(store.getTypeName(for: previous1Club))
                                .font(.system(size: adjacent1Size, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.7)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )
                                .offset(y: -adjacent1Height)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        // Previous -2 (second from top) - only show if currentIndex >= 2
                        if currentIndex >= 2 {
                            Text(store.getTypeName(for: previous2Club))
                                .font(.system(size: adjacent2Size, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.45)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                                .offset(y: -(adjacent1Height + adjacent2Height))
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }

                    // Two clubs below when scrolling (only if not at bottom)
                    if isCrownScrolling {
                        // Next +1 (directly below current) - only show if not at last club
                        if currentIndex < clubs.count - 1 {
                            Text(store.getTypeName(for: next1Club))
                                .font(.system(size: adjacent1Size, weight: .medium))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.7)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                                )
                                .offset(y: adjacent1Height)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // Next +2 (second from bottom) - only show if at least 2 clubs remaining
                        if currentIndex < clubs.count - 2 {
                            Text(store.getTypeName(for: next2Club))
                                .font(.system(size: adjacent2Size, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.45)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                                )
                                .offset(y: adjacent1Height + adjacent2Height)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
            .padding(.trailing, 8)
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: isCrownScrolling)
        .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
        } // end else clubs.isEmpty
    }

    @ViewBuilder
    private func buttonsOverlay(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: 4) {
                // Left: Stack of buttons (bottom to top: penalty, target)
                VStack(spacing: 4) {
                    // Target button (top) - hide when placing penalty or no hole
                    if !isPlacingPenalty && store.currentHole != nil {
                        Button(action: toggleTargetPlacement) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.95))
                                    .frame(width: buttonSize, height: buttonSize)
                                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                if isPlacingTarget {
                                    Circle()
                                        .stroke(Color.yellow, lineWidth: 3)
                                        .frame(width: buttonSize, height: buttonSize)
                                }

                                Image(systemName: "scope")
                                    .font(.system(size: iconSize, weight: .bold))
                                    .foregroundColor(.black)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    // Orange penalty button (bottom) - changes to checkmark when placed - hide when no hole
                    if !isPlacingTarget && store.currentHole != nil {
                        Button(action: togglePenaltyPlacement) {
                            ZStack {
                                Circle()
                                    .fill(Color.orange.opacity(0.95))
                                    .frame(width: buttonSize, height: buttonSize)
                                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                if isPlacingPenalty && temporaryPenaltyPosition != nil {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.white)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false && !isPlacingPenalty)
                        .opacity((store.currentHole.map { store.isHoleCompleted($0.number) } ?? false && !isPlacingPenalty) ? 0.3 : 0.95)
                    }
                }

                Spacer()

                // Right: Stack of buttons (bottom to top: shot, direction)
                VStack(spacing: 4) {
                    // Blue aim direction button (top) - hide when no hole
                    if store.currentHole != nil {
                        Button(action: captureAimDirection) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.95))
                                    .frame(width: buttonSize, height: buttonSize)
                                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                Image(systemName: "location.north.fill")
                                    .font(.system(size: iconSize, weight: .bold))
                                    .foregroundColor(.white)
                                    .rotationEffect(.degrees(aimArrowRotation))
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false)
                        .opacity(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false ? 0.3 : 0.95)
                    }

                    // Green stroke button (bottom) - always show
                    Button(action: recordStroke) {
                        ZStack {
                            Circle()
                                .fill(showingRecordedFeedback ? Color.white.opacity(0.95) : Color.green.opacity(0.95))
                                .frame(width: buttonSize, height: buttonSize)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                            Image(systemName: showingRecordedFeedback ? "checkmark" : "plus")
                                .font(.system(size: iconSize, weight: .bold))
                                .foregroundColor(showingRecordedFeedback ? .green : .white)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false)
                    .opacity(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false ? 0.3 : 0.95)
                }
                .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func swingDetectedOverlay(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        if swingDetector.lastDetectedSwing != nil && store.currentHole != nil && !isPlacingTarget && !isPlacingPenalty && !isPlacingHole {
            VStack(spacing: 4) {
                // Main swing button - tap to add stroke
                Button(action: addStrokeFromLastSwing) {
                    ZStack {
                        // Outer pulse ring for motion effect
                        Circle()
                            .stroke(Color.cyan.opacity(0.3), lineWidth: 2)
                            .frame(width: buttonSize * 1.7, height: buttonSize * 1.7)
                            .scaleEffect(isPulsing ? 1.18 : 0.92)
                            .opacity(isPulsing ? 0.0 : 0.8)
                            .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false),
                                       value: isPulsing)

                        Circle()
                            .fill(Color.cyan.opacity(0.7))
                            .frame(width: buttonSize * 1.5, height: buttonSize * 1.5)
                            .shadow(color: .cyan.opacity(0.4), radius: 8, x: 0, y: 0)

                        // Motion lines behind the golfer
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.white.opacity(0.4 - Double(i) * 0.1))
                                    .frame(width: 2, height: CGFloat(8 - i * 2))
                            }
                            Spacer()
                        }
                        .frame(width: buttonSize * 1.2)
                        .offset(x: -iconSize * 0.3)

                        Image(systemName: "figure.golf")
                            .font(.system(size: iconSize * 1.4, weight: .bold))
                            .foregroundColor(.white)
                            .rotationEffect(.degrees(-8))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .onAppear {
                    // This single change starts the forever animation.
                    isPulsing = true
                }
                .onDisappear {
                    // Optional: helps if the view reappears and you want it to restart cleanly.
                    isPulsing = false
                }

                // Dismiss button - smaller X below, closer
                Button(action: {
                    swingDetector.clearLastSwing()
                    WKInterfaceDevice.current().play(.click)
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.7))
                            .frame(width: buttonSize * 0.6, height: buttonSize * 0.6)

                        Image(systemName: "xmark")
                            .font(.system(size: iconSize * 0.5, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            .offset(y: -15)
            .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var swipeUpIndicator: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                // Swipe indicator pill
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 30, height: 5)
                    .padding(.bottom, 4)
                    .onTapGesture {
                        showingActionsSheet = true
                    }

                Spacer()
            }
        }
        .ignoresSafeArea()
        .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
    }

    @ViewBuilder
    private func penaltyCancelButton(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom) {
                Spacer()

                Button(action: {
                    isPlacingPenalty = false
                    temporaryPenaltyPosition = nil
                    isMapFocused = false
                    isMainViewFocused = true
                    updateMapPosition()
                    WKInterfaceDevice.current().play(.click)
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.95))
                            .frame(width: buttonSize, height: buttonSize)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                        Image(systemName: "xmark")
                            .font(.system(size: iconSize, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func parButtonsOverlay() -> some View {
        VStack {
            Spacer()

            HStack(spacing: 8) {
                // Par 3 button
                Button(action: { saveHole(par: 3) }) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.95))
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                        Text("3")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())

                // Par 4 button
                Button(action: { saveHole(par: 4) }) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.95))
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                        Text("4")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())

                // Par 5 button
                Button(action: { saveHole(par: 5) }) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.95))
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                        Text("5")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func holePlacementCancelButton(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom) {
                Spacer()

                Button(action: {
                    isPlacingHole = false
                    temporaryHolePosition = nil
                    isMapFocused = false
                    isMainViewFocused = true
                    if store.currentHole != nil {
                        updateMapPosition()
                    } else {
                        updateNoHoleMapPosition()
                    }
                    WKInterfaceDevice.current().play(.click)
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.95))
                            .frame(width: buttonSize, height: buttonSize)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                        Image(systemName: "xmark")
                            .font(.system(size: iconSize, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var holeInfoOverlay: some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                if let hole = store.currentHole {
                    let parText = hole.par.map { String($0) } ?? "-"

                    // Main container: Yards + H/P row
                    VStack(alignment: .leading, spacing: 4) {
                        Text(distanceToHole.map { String($0) } ?? "XXX")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        HStack(spacing: 8) {
                            Text("H: \(hole.number)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                            Text("P: \(parText)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(4)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .fixedSize()

                    // Separate strokes container
                    Text("S: \(store.strokeCount(for: hole))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.55, green: 0.85, blue: 0.55))
                        .padding(4)
                        .background(Color.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .fixedSize()
                } else {
                    // No hole defined - show flag button
                    Button(action: {
                        isPlacingHole = true
                        isMapFocused = true
                        isMainViewFocused = false
                        WKInterfaceDevice.current().play(.click)
                    }) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.yellow)
                            .padding(8)
                            .background(Color.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.leading, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ignoresSafeArea()
        .opacity(isPlacingTarget || isPlacingPenalty || isPlacingHole ? 0 : 1)
    }

    private var aimArrowRotation: Double {
        guard let capturedHeading = swingDetector.capturedAimDirection,
              let userLocation = locationManager.location,
              let hole = store.currentHole else {
            return 0 // Arrow points up when not set
        }

        // Calculate bearing to hole
        let bearingToHole = calculateBearing(from: userLocation.coordinate, to: hole.coordinate)

        // Calculate offset: how much the aim direction differs from hole bearing
        // Positive = aiming right of hole, Negative = aiming left of hole
        let offset = (capturedHeading - bearingToHole + 360).truncatingRemainder(dividingBy: 360)

        // Convert to -180 to 180 range for cleaner display
        let normalizedOffset = offset > 180 ? offset - 360 : offset

        return normalizedOffset
    }

    @ViewBuilder
    private func mainContent(geometry: GeometryProxy) -> some View {
        let buttonSize = geometry.size.width * 0.25
        let iconSize = buttonSize * 0.45
        let clubFontSize = geometry.size.width * 0.055

        ZStack {
            // Full screen map
            if let hole = store.currentHole {
                mapView(for: hole)
                    .ignoresSafeArea()
            } else {
                // No hole defined - show map centered on user
                noHoleMapView()
                    .ignoresSafeArea()
            }

            // Club selector overlay (positioned at crown height)
            clubSelectorOverlay(clubFontSize: clubFontSize)

            // Info overlay (top left) - distance and hole info (or flag button when no hole)
            holeInfoOverlay

            // Buttons overlay (bottom) - show unless placing hole
            if !isPlacingHole {
                buttonsOverlay(buttonSize: buttonSize, iconSize: iconSize)
            }

            // Swing detected overlay (centered)
            swingDetectedOverlay(buttonSize: buttonSize, iconSize: iconSize)

            // Bottom swipe-up indicator
            swipeUpIndicator

            // Cancel button for penalty placement (bottom right)
            if isPlacingPenalty {
                penaltyCancelButton(buttonSize: buttonSize, iconSize: iconSize)
            }

            // Par buttons for hole placement
            if isPlacingHole && temporaryHolePosition != nil {
                parButtonsOverlay()
            }

            // Cancel button for hole placement
            if isPlacingHole {
                holePlacementCancelButton(buttonSize: buttonSize, iconSize: iconSize)
            }

            // Invisible button for double-tap gesture (clench fingers twice)
            // Uses detected swing if available, otherwise adds regular stroke
            Button(action: handleDoubleTapGesture) {
                Color.clear
                    .frame(width: 1, height: 1)
            }
            .buttonStyle(PlainButtonStyle())
            .handGestureShortcut(.primaryAction)
            .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false || isPlacingTarget || isPlacingPenalty || isPlacingHole)
        }
        .task {
            calculateCrownOffset(screenHeight: geometry.size.height)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            mainContent(geometry: geometry)
        }
        .toolbar(.hidden, for: .navigationBar)
        .focusable()
        .focused($isMainViewFocused)
        .digitalCrownRotation(
            $selectedClubIndex,
            from: 0,
            through: Double(max(clubs.count - 1, 0)),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .digitalCrownAccessory(.hidden)
        .sheet(isPresented: $showingActionsSheet) {
            actionsSheet
        }
        .sheet(isPresented: $showingEditHole) {
            if let hole = store.currentHole {
                EditHoleView(store: store, locationManager: locationManager, hole: hole, isPresented: $showingEditHole)
            }
        }
        .sheet(isPresented: $showingAddHole) {
            AddHoleView(store: store, locationManager: locationManager, isPresented: $showingAddHole)
        }
        .sheet(isPresented: $showingDistanceEditor) {
            ClubDistanceEditorView(store: store)
        }
        .navigationDestination(isPresented: $navigateToAddHole) {
            AddHoleNavigationView(store: store, locationManager: locationManager)
        }
        .onAppear {
            print("⌚ [ActiveRoundView] View appeared")
            print("⌚ [ActiveRoundView] Current location: \(locationManager.location?.description ?? "nil")")
            print("⌚ [ActiveRoundView] Authorization status: \(locationManager.authorizationStatus)")
            locationManager.requestPermission()
            locationManager.startTracking()
            print("⌚ [ActiveRoundView] Called requestPermission and startTracking")
            updateMapPosition()
            // Set focus to main view for crown control
            isMainViewFocused = true
            // Start swing detection
            swingDetector.startMonitoring()

            // Request HealthKit authorization and start workout if there's an active round
            if store.currentRound != nil && !workoutManager.isWorkoutActive {
                workoutManager.requestAuthorization { success in
                    if success {
                        print("⌚ [ActiveRoundView] HealthKit authorized, starting workout")
                        workoutManager.startWorkout()
                    } else {
                        print("⌚ [ActiveRoundView] HealthKit authorization failed")
                    }
                }
            }
        }
        .onDisappear {
            // Stop swing detection when leaving the view
            swingDetector.stopMonitoring()
            // Clean up crown scroll timer
            crownScrollTimer?.invalidate()
            // Note: We don't stop the workout here - it should continue in background
            // Only stop when the round is explicitly ended
        }
        .onChange(of: locationManager.location) { _, _ in
            // Trigger view refresh when location updates (for distance display)
            // Also update map orientation to keep user at bottom, flag at top
            if !isPlacingTarget {
                updateMapPosition()
            }
        }
        .onChange(of: distanceToHole) { _, newDistance in
            // Auto-predict club based on distance if enabled and not manually overridden
            guard !manualClubOverride,
                  store.clubPredictionMode != .off,
                  let distance = newDistance else { return }

            if let predictedIndex = ClubPredictionManager.shared.predictClubIndex(
                forDistance: distance,
                clubs: clubs,
                clubTypes: store.clubTypes,
                mode: store.clubPredictionMode,
                customAverages: store.customClubAverages
            ) {
                isAutoSelectingClub = true
                selectedClubIndex = Double(predictedIndex)
                isAutoSelectingClub = false
            }
        }
        .onChange(of: locationManager.heading) { _, _ in
            // Trigger view refresh when heading updates (to rotate user arrow)
        }
        .onChange(of: store.currentHoleIndex) { _, _ in
            // Watch syncs hole index from phone - update map when it changes
            manualClubOverride = false  // Reset manual override on hole change
            updateMapPosition()
        }
        .onChange(of: store.currentHole) { _, _ in
            // Update map when hole changes (also covers new holes added from phone)
            updateMapPosition()
        }
        .onChange(of: showingActionsSheet) { _, isShowing in
            // When actions sheet closes, restore focus to main view
            if !isShowing {
                isMainViewFocused = true
            }
        }
        .onChange(of: selectedClubIndex) { _, _ in
            // Detect manual club change (user scrolling vs auto-prediction)
            if !isAutoSelectingClub && store.clubPredictionMode != .off {
                manualClubOverride = true
            }

            // Crown is being scrolled - show enlarged text
            withAnimation(.easeInOut(duration: 0.15)) {
                isCrownScrolling = true
            }

            // Cancel existing timer
            crownScrollTimer?.invalidate()

            // Set new timer to detect when scrolling stops
            crownScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCrownScrolling = false
                }
            }
        }
    }

    // MARK: - Map View

    @ViewBuilder
    private func mapView(for hole: Hole) -> some View {
        if store.satelliteModeEnabled,
           let round = store.currentRound,
           satelliteCache.hasCachedImages(for: round.courseId) {
            satelliteImageView(for: hole)
        } else {
            standardMapView(for: hole)
        }
    }

    @ViewBuilder
    private func satelliteImageView(for hole: Hole) -> some View {
        if let round = store.currentRound,
           let userLocation = locationManager.location {

            let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
            let targetsForHole = round.targets.filter { $0.holeNumber == hole.number }

            // Calculate camera info for satellite view - MUST match updateMapPosition behavior
            // Determine start coordinate based on view mode (ternary to avoid if-else in @ViewBuilder)
            let startCoord = (isFullViewMode && firstStroke != nil) ? firstStroke!.coordinate : userLocation.coordinate

            let bearing = calculateBearing(from: startCoord, to: hole.coordinate)
            let holeLocation = CLLocation(latitude: hole.coordinate.latitude, longitude: hole.coordinate.longitude)
            let startLocation = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
            let distance = startLocation.distance(from: holeLocation)

            // Calculate center point - 45%/50% between start and hole (SAME as regular map)
            let centerLat = startCoord.latitude + (hole.coordinate.latitude - startCoord.latitude) * 0.45
            let centerLon = startCoord.longitude + (hole.coordinate.longitude - startCoord.longitude) * 0.5

            let cameraInfo = MapCameraInfo(
                centerCoordinate: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                bearing: bearing,
                distance: max(distance * 2.5, 100)
            )

            SatelliteImageView(
                courseId: round.courseId,
                holeNumber: hole.number,
                userLocation: userLocation,
                hole: hole,
                strokes: strokesForHole,
                targets: targetsForHole,
                lastRealStroke: lastRealStroke,
                temporaryPenaltyPosition: temporaryPenaltyPosition,
                heading: locationManager.heading,
                mapCamera: cameraInfo,
                isPlacingTarget: isPlacingTarget,
                isPlacingPenalty: isPlacingPenalty,
                onTap: { coordinate in
                    handleSatelliteViewTap(coordinate: coordinate)
                }
            )
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func noHoleMapView() -> some View {
        MapReader { proxy in
            Map(position: $position) {
                // User location
                if let userLocation = locationManager.location {
                    Annotation("", coordinate: userLocation.coordinate) {
                        let relativeHeading = locationManager.heading ?? 0

                        Image(systemName: "location.north.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                            .rotationEffect(.degrees(relativeHeading))
                            .shadow(color: .white, radius: 2)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                }

                // Stroke markers - show all strokes for current hole even if no hole is defined
                if let round = store.currentRound, let course = store.getCourse(for: round) {
                    let nextHoleNumber = course.holes.count + 1
                    let strokesForHole = round.strokes.filter { $0.holeNumber == nextHoleNumber }
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(stroke.isPenalty ? .orange : .white)
                                    .frame(width: 20, height: 20)
                                    .opacity(0.85)
                                    .shadow(color: .black, radius: 2)

                                Text("\(stroke.strokeNumber)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(stroke.isPenalty ? .white : .black)
                            }
                        }
                    }
                }

                // Temporary hole position marker
                if isPlacingHole, let holePos = temporaryHolePosition {
                    Annotation("", coordinate: holePos) {
                        Image(systemName: "flag.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 24))
                            .shadow(color: .black, radius: 2)
                    }
                }
            }
            .mapStyle(.standard)
            .mapControls {}
            .mapControlVisibility(.hidden)
            .allowsHitTesting(isPlacingHole)
            .focusable(isPlacingHole)
            .focused($isMapFocused)
            .onTapGesture { screenLocation in
                guard isPlacingHole, let coordinate = proxy.convert(screenLocation, from: .local) else { return }
                temporaryHolePosition = coordinate
                WKInterfaceDevice.current().play(.click)
            }
        }
        .onAppear {
            updateNoHoleMapPosition()
        }
    }

    @ViewBuilder
    private func standardMapView(for hole: Hole) -> some View {
        MapReader { proxy in
            Map(position: $position) {
                // Hole marker (top) - green if completed, yellow if not
                Annotation("", coordinate: hole.coordinate) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 20))
                        .foregroundColor(store.isHoleCompleted(hole.number) ? .green : .yellow)
                }

                // User location (bottom)
                if let userLocation = locationManager.location {
                    Annotation("", coordinate: userLocation.coordinate) {
                        let relativeHeading: Double = {
                            guard let heading = locationManager.heading else { return 0 }
                            // Map is rotated by bearing to hole, so arrow needs to compensate
                            let bearingToHole = calculateBearing(from: userLocation.coordinate, to: hole.coordinate)
                            return (heading - bearingToHole + 360).truncatingRemainder(dividingBy: 360)
                        }()

                        Image(systemName: "location.north.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                            .rotationEffect(.degrees(relativeHeading))
                            .shadow(color: .white, radius: 2)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                }

                // Stroke markers - show only in full view mode
                if isFullViewMode, let round = store.currentRound {
                    let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                // Full view mode - white circles
                                Circle()
                                    .fill(stroke.isPenalty ? .orange : .white)
                                    .frame(width: 12, height: 12)
                                    .opacity(0.9)
                                    .shadow(color: .black, radius: 2)

                                // Show distance for all strokes in full view mode
                                let distance: Int? = {
                                    if let lastStroke = strokesForHole.last, stroke.id == lastStroke.id {
                                        // Last stroke - dynamic distance to user
                                        return distanceToTarget(stroke.coordinate)
                                    } else if let nextIndex = strokesForHole.firstIndex(where: { $0.id == stroke.id }),
                                              nextIndex + 1 < strokesForHole.count {
                                        // Not last stroke - static distance to next stroke
                                        let nextStroke = strokesForHole[nextIndex + 1]
                                        let loc1 = CLLocation(latitude: stroke.coordinate.latitude, longitude: stroke.coordinate.longitude)
                                        let loc2 = CLLocation(latitude: nextStroke.coordinate.latitude, longitude: nextStroke.coordinate.longitude)
                                        return Int(loc1.distance(from: loc2) * 1.09361)
                                    }
                                    return nil
                                }()

                                if let dist = distance {
                                    VStack {
                                        Text("\(dist)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.black)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Color.white.opacity(0.9))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                            .offset(y: -12)
                                        Spacer()
                                    }
                                    .frame(height: 12)
                                }
                            }
                        }
                    }
                }

                // Target markers
                ForEach(Array(targetCoordinatesBinding.wrappedValue.enumerated()), id: \.offset) { index, target in
                    Annotation("", coordinate: target) {
                        ZStack {
                            Image(systemName: "scope")
                                .font(.system(size: 24))
                                .foregroundColor(.white)
                                .shadow(color: .black, radius: 2)

                            if let distance = distanceToTarget(target) {
                                VStack {
                                    Spacer()
                                    Text("\(distance)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.9))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .offset(y: 18) // Position below the scope icon
                                }
                                .frame(height: 24)
                            }
                        }
                        .frame(width: 24, height: 24)
                    }
                }

                // Temporary penalty position marker
                if isPlacingPenalty, let penaltyPos = temporaryPenaltyPosition {
                    Annotation("", coordinate: penaltyPos) {
                        ZStack {
                            Circle()
                                .fill(.orange)
                                .frame(width: 28, height: 28)
                                .shadow(color: .black, radius: 2)

                            if let round = store.currentRound, let hole = store.currentHole {
                                let strokeCount = round.strokes.filter { $0.holeNumber == hole.number }.count
                                Text("\(strokeCount + 1)")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard)
            .mapControls {
                // Disable default map controls (including crown zoom and legal label)
            }
            .mapControlVisibility(.hidden) // Hide legal/attribution label
            .allowsHitTesting(isPlacingTarget || isPlacingPenalty)
            .focusable(isPlacingTarget || isPlacingPenalty)
            .focused($isMapFocused)
            .onTapGesture { screenLocation in
                guard let coordinate = proxy.convert(screenLocation, from: .local) else { return }

                if isPlacingTarget {
                    var coords = targetCoordinatesBinding.wrappedValue
                    let tappedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

                    // Check if tap is within 20 yards (~18 meters) of any existing target
                    let deletionRadius: Double = 18.0 // meters (approximately 20 yards)
                    var deletedIndex: Int?

                    for (index, targetCoord) in coords.enumerated() {
                        let targetLocation = CLLocation(latitude: targetCoord.latitude, longitude: targetCoord.longitude)
                        let distance = tappedLocation.distance(from: targetLocation)

                        if distance <= deletionRadius {
                            deletedIndex = index
                            break
                        }
                    }

                    if let indexToDelete = deletedIndex {
                        // Delete the nearby target
                        coords.remove(at: indexToDelete)
                        targetCoordinatesBinding.wrappedValue = coords
                        WKInterfaceDevice.current().play(.click)
                    } else {
                        // Add new target
                        coords.append(coordinate)
                        targetCoordinatesBinding.wrappedValue = coords
                        WKInterfaceDevice.current().play(.success)
                    }
                } else if isPlacingPenalty {
                    // Update penalty position
                    temporaryPenaltyPosition = coordinate
                    WKInterfaceDevice.current().play(.click)
                }
            }
        }
    }

    // MARK: - Actions Sheet

    @ViewBuilder
    private var actionsSheet: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Top row: Hole navigation
                if let hole = store.currentHole, let round = store.currentRound, let course = store.getCourse(for: round) {
                    HStack(spacing: 12) {
                        // Left arrow - previous hole
                        Button(action: {
                            store.navigateToPreviousHole()
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.blue.opacity(0.9))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(store.currentHoleIndex == 0)
                        .opacity(store.currentHoleIndex == 0 ? 0.3 : 1.0)

                        // Hole number
                        Text("Hole \(hole.number)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)

                        // Right arrow or plus - next hole or add hole
                        if store.currentHoleIndex < course.holes.count - 1 {
                            // Next hole exists - show right arrow
                            Button(action: {
                                store.navigateToNextHole()
                            }) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.blue.opacity(0.9))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        } else {
                            // Last hole - show plus to add new hole
                            Button(action: {
                                showingActionsSheet = false
                                navigateToAddHole = true
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.green.opacity(0.9))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 8)
                }

                // Second row: Undo and Edit buttons
                HStack(spacing: 8) {
                    // Undo button - shows confirmation
                    Button(action: {
                        showingUndoConfirmation = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 14, weight: .bold))
                            Text("Undo")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!canUndo)
                    .opacity(canUndo ? 1.0 : 0.5)

                    // Edit Hole button
                    Button(action: {
                        showingActionsSheet = false
                        showingEditHole = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "flag")
                                .font(.system(size: 16, weight: .bold))
                            Text("Edit")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 8)

                // Third row: Home button (moved above options)
                HStack(spacing: 8) {
                    Button(action: {
                        showingActionsSheet = false
                        dismiss()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "house.fill")
                                .font(.system(size: 14, weight: .bold))
                            Text("Home")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.gray.opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 8)

                // Fourth row: Full View and Satellite toggles
                HStack(spacing: 8) {
                    // Full View Mode Toggle (left)
                    Button(action: {
                        isFullViewMode.toggle()
                        WKInterfaceDevice.current().play(.click)
                        // Update map position based on new mode
                        if store.currentHole != nil {
                            updateMapPosition()
                        } else {
                            updateNoHoleMapPosition()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: isFullViewMode ? "scope" : "scope")
                                .font(.system(size: 14, weight: .bold))
                            Text(isFullViewMode ? "Full: ON" : "Full: OFF")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background((isFullViewMode ? Color.green : Color.gray).opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())

                    // Satellite Mode Toggle (right)
                    Button(action: {
                        store.satelliteModeEnabled.toggle()
                        WKInterfaceDevice.current().play(.click)
                        print("⌚ [ActiveRound] Satellite mode toggled to: \(store.satelliteModeEnabled)")
                    }) {
                        let currentCourseId = store.currentRound?.courseId ?? UUID()
                        let hasImages = satelliteCache.hasCachedImages(for: currentCourseId)
                        let _ = print("⌚ [ActiveRound] Button render - CourseID: \(currentCourseId), Has images: \(hasImages)")

                        HStack(spacing: 6) {
                            Image(systemName: store.satelliteModeEnabled ? "map.fill" : "map")
                                .font(.system(size: 14, weight: .bold))
                            Text(store.satelliteModeEnabled ? "Sat: ON" : "Sat: OFF")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background((store.satelliteModeEnabled ? Color.green : Color.gray).opacity(0.9))
                        .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!satelliteCache.hasCachedImages(for: store.currentRound?.courseId ?? UUID()))
                    .opacity(satelliteCache.hasCachedImages(for: store.currentRound?.courseId ?? UUID()) ? 1.0 : 0.5)
                }
                .padding(.horizontal, 8)

                // Fifth row: Predict Club setting
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Predict Club")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            Text("auto-select club based on distance")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        // Edit button for Manual mode
                        if store.clubPredictionMode == .manual {
                            Button(action: {
                                showingActionsSheet = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showingDistanceEditor = true
                                }
                            }) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(8)
                                    .background(Color.blue.opacity(0.9))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.bottom, 2)

                    // Mode selector buttons
                    HStack(spacing: 4) {
                        ForEach(ClubPredictionMode.allCases, id: \.self) { mode in
                            Button(action: {
                                store.clubPredictionMode = mode
                                manualClubOverride = false  // Reset override when mode changes
                                WKInterfaceDevice.current().play(.click)
                            }) {
                                Text(mode.rawValue)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(store.clubPredictionMode == mode ? .white : .gray)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        store.clubPredictionMode == mode ? Color.green.opacity(0.9) : Color.gray.opacity(0.3)
                                    )
                                    .cornerRadius(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding()
        }
        .confirmationDialog("Undo Last Stroke?", isPresented: $showingUndoConfirmation, titleVisibility: .visible) {
            Button("Undo", role: .destructive) {
                deleteLastStroke()
                showingActionsSheet = false
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Actions

    private func handleSatelliteViewTap(coordinate: CLLocationCoordinate2D) {
        if isPlacingTarget {
            var coords = targetCoordinatesBinding.wrappedValue
            let tappedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

            // Check if tap is within 20 yards (~18 meters) of any existing target
            let deletionRadius: Double = 18.0 // meters (approximately 20 yards)
            var deletedIndex: Int?

            for (index, targetCoord) in coords.enumerated() {
                let targetLocation = CLLocation(latitude: targetCoord.latitude, longitude: targetCoord.longitude)
                let distance = tappedLocation.distance(from: targetLocation)

                if distance <= deletionRadius {
                    deletedIndex = index
                    break
                }
            }

            if let indexToDelete = deletedIndex {
                // Delete the nearby target
                coords.remove(at: indexToDelete)
                targetCoordinatesBinding.wrappedValue = coords
                WKInterfaceDevice.current().play(.click)
            } else {
                // Add new target
                coords.append(coordinate)
                targetCoordinatesBinding.wrappedValue = coords
                WKInterfaceDevice.current().play(.success)
            }
        } else if isPlacingPenalty {
            // Update penalty position
            temporaryPenaltyPosition = coordinate
            WKInterfaceDevice.current().play(.click)
        }
    }

    private func captureAimDirection() {
        print("⌚ [AimDirection] Button tapped")
        print("⌚ [AimDirection] Current heading: \(locationManager.heading?.description ?? "nil")")

        var heading: Double?

        // Try to get real heading first
        if let realHeading = locationManager.heading {
            heading = realHeading
        } else if let userLocation = locationManager.location,
                  let hole = store.currentHole {
            // Fallback: Use bearing to hole + 45 degrees as simulated offset
            // This allows testing in simulator
            let bearingToHole = calculateBearing(from: userLocation.coordinate, to: hole.coordinate)
            heading = (bearingToHole + 45).truncatingRemainder(dividingBy: 360)
            print("⌚ [AimDirection] Using simulated heading (bearing + 45°)")
        }

        guard let finalHeading = heading else {
            // No heading available, vibrate to indicate error
            print("⌚ [AimDirection] ERROR: No heading or location available")
            WKInterfaceDevice.current().play(.failure)
            return
        }

        // Capture the current heading in SwingDetectionManager so it persists with detected swings
        swingDetector.capturedAimDirection = finalHeading
        print("⌚ [AimDirection] Captured heading: \(finalHeading)")

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)
    }

    private func recordStroke() {
        // If no aim direction was captured, default to bearing towards the flag (if hole exists)
        var trajectoryHeading = swingDetector.capturedAimDirection
        if trajectoryHeading == nil,
           let userLocation = locationManager.location,
           let hole = store.currentHole {
            trajectoryHeading = calculateBearing(from: userLocation.coordinate, to: hole.coordinate)
            print("⌚ [RecordStroke] No captured heading, using bearing to flag: \(trajectoryHeading!)")
        }

        // Pass the trajectory heading to the stroke
        // This works even if there's no hole - addStroke will use the next hole number
        guard let club = selectedClub else {
            print("⌚ [RecordStroke] ERROR: No club selected")
            return
        }
        store.addStroke(clubId: club.id, trajectoryHeading: trajectoryHeading)

        // Reset manual club override so auto-prediction resumes
        manualClubOverride = false

        // Reset aim direction after stroke is recorded
        swingDetector.capturedAimDirection = nil

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)

        // Visual feedback
        withAnimation(.easeInOut(duration: 0.3)) {
            showingRecordedFeedback = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showingRecordedFeedback = false
            }
        }
    }

    private func handleDoubleTapGesture() {
        // If there's a detected swing, add that. Otherwise, add a regular stroke.
        if swingDetector.lastDetectedSwing != nil && store.currentHole != nil {
            addStrokeFromLastSwing()
        } else {
            recordStroke()
        }
    }

    private func addStrokeFromLastSwing() {
        guard let swing = swingDetector.lastDetectedSwing else {
            print("⌚ [AddLastSwing] No swing detected")
            return
        }

        guard var round = store.currentRound,
              let hole = store.currentHole else {
            print("⌚ [AddLastSwing] No active round or hole")
            return
        }

        let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
        let strokeNumber = strokesForHole.count + 1

        // Use aim direction captured at swing detection time, fall back to bearing towards flag
        var trajectoryHeading = swing.trajectoryHeading
        if trajectoryHeading == nil {
            // Default to bearing towards the flag
            trajectoryHeading = calculateBearing(from: swing.location, to: hole.coordinate)
        }

        guard let club = selectedClub else {
            print("⌚ [RecordStrokeFromMotion] ERROR: No club selected")
            return
        }

        let stroke = Stroke(
            holeNumber: hole.number,
            strokeNumber: strokeNumber,
            coordinate: swing.location,
            clubId: club.id,
            trajectoryHeading: trajectoryHeading,
            acceleration: swing.peakAcceleration
        )

        // Add to current round
        round.strokes.append(stroke)
        store.currentRound = round

        // Save locally
        store.saveToStorage()

        // Sync to iPhone
        WatchConnectivityManager.shared.sendRound(round)

        // Reset manual club override so auto-prediction resumes
        manualClubOverride = false

        // Reset aim direction after stroke is recorded
        swingDetector.capturedAimDirection = nil

        // Clear the last swing
        swingDetector.clearLastSwing()

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)

        print("⌚ [AddLastSwing] Added stroke from detected swing at \(swing.location) with \(swing.peakAcceleration)G")
    }

    private func deleteLastStroke() {
        store.deleteLastStroke()

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)
    }

    private func togglePenaltyPlacement() {
        if isPlacingPenalty && temporaryPenaltyPosition != nil {
            // Save the penalty stroke
            guard let penaltyCoord = temporaryPenaltyPosition,
                  var round = store.currentRound,
                  let hole = store.currentHole else { return }

            // Add penalty stroke using selected club
            guard let club = selectedClub else {
                print("⌚ [TogglePenaltyPlacement] ERROR: No club selected")
                return
            }

            let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
            let strokeNumber = strokesForHole.count + 1

            let stroke = Stroke(
                holeNumber: hole.number,
                strokeNumber: strokeNumber,
                coordinate: penaltyCoord,
                clubId: club.id,
                isPenalty: true
            )

            round.strokes.append(stroke)
            store.currentRound = round
            store.saveToStorage()

            // Sync to iPhone
            WatchConnectivityManager.shared.sendRound(round)

            // Haptic and audio feedback - failure for penalty (bad thing)
            WKInterfaceDevice.current().play(.failure)

            // Exit placement mode
            isPlacingPenalty = false
            temporaryPenaltyPosition = nil
            isMapFocused = false
            isMainViewFocused = true

            // Update map position to show hole at top, user at bottom
            updateMapPosition()
        } else if !isPlacingPenalty {
            // Enter penalty placement mode - wait for user to tap to place
            isPlacingPenalty = true
            temporaryPenaltyPosition = nil
            isMapFocused = true
            isMainViewFocused = false
            WKInterfaceDevice.current().play(.click)
        }
    }

    private func finishCurrentHole() {
        // Check if this is the last hole before finishing
        let isLastHole: Bool = {
            guard let round = store.currentRound,
                  let course = store.getCourse(for: round) else { return false }
            return store.currentHoleIndex >= course.holes.count - 1
        }()

        store.finishCurrentHole()

        // Haptic feedback - directionUp for hole completion
        WKInterfaceDevice.current().play(.directionUp)

        // If this was the last hole, automatically show add hole view
        if isLastHole {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                navigateToAddHole = true
            }
        }
    }

    private func toggleTargetPlacement() {
        isPlacingTarget.toggle()
        WKInterfaceDevice.current().play(.click)

        // When exiting target mode, reposition map
        if !isPlacingTarget {
            isMapFocused = false
            isMainViewFocused = true
            // Force immediate map update when exiting target mode
            DispatchQueue.main.async {
                updateMapPosition()
            }
        } else {
            isMapFocused = true
            isMainViewFocused = false
        }
    }

    private func saveHole(par: Int) {
        guard let coordinate = temporaryHolePosition else { return }

        // Add hole to course via store with par
        store.addHole(coordinate: coordinate, par: par)

        // Exit placement mode
        isPlacingHole = false
        temporaryHolePosition = nil
        isMapFocused = false
        isMainViewFocused = true

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)

        // Update map position to show hole at top, user at bottom
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            updateMapPosition()
        }
    }

    private func updateMapPosition() {
        // Don't update map during target placement mode
        guard !isPlacingTarget else { return }

        guard let hole = store.currentHole else { return }

        let holeCoord = hole.coordinate

        // Determine start coordinate based on view mode
        let startCoord: CLLocationCoordinate2D
        if isFullViewMode, let first = firstStroke {
            // Full view mode with strokes - anchor to first stroke
            startCoord = first.coordinate
        } else if let userLocation = locationManager.location {
            // Default mode or no strokes yet - use user location
            startCoord = userLocation.coordinate
        } else {
            // No user location - can't position map
            return
        }

        // Calculate bearing from start to hole
        let bearing = calculateBearing(from: startCoord, to: holeCoord)

        // Calculate distance
        let holeLocation = CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude)
        let startLocation = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
        let distance = startLocation.distance(from: holeLocation)

        // Calculate center point - balanced between start and hole
        let centerLat = startCoord.latitude + (holeCoord.latitude - startCoord.latitude) * 0.45
        let centerLon = startCoord.longitude + (holeCoord.longitude - startCoord.longitude) * 0.5

        // Create camera oriented with start at bottom, hole at top
        let camera = MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            distance: max(distance * 2.5, 100), // Zoom to show both points with padding
            heading: bearing, // Rotate so hole is "up"
            pitch: 0
        )

        position = .camera(camera)
    }

    private func updateNoHoleMapPosition() {
        guard let userLocation = locationManager.location else { return }

        // Show 500 yards (~457 meters) north and south from user
        // Total height is ~914 meters, so distance should be ~457 meters
        let camera = MapCamera(
            centerCoordinate: userLocation.coordinate,
            distance: 914, // ~1000 yards total view (500 N + 500 S)
            heading: 0, // North-aligned
            pitch: 0
        )

        position = .camera(camera)
    }

    private func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = from.latitude * .pi / 180.0
        let lon1 = from.longitude * .pi / 180.0
        let lat2 = to.latitude * .pi / 180.0
        let lon2 = to.longitude * .pi / 180.0

        let dLon = lon2 - lon1

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x)

        let bearingDegrees = bearing * 180.0 / .pi
        return (bearingDegrees + 360.0).truncatingRemainder(dividingBy: 360.0)
    }

    private func calculateCoordinate(from: CLLocationCoordinate2D, bearing: Double, distanceMeters: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6371000.0 // meters
        let bearingRadians = bearing * .pi / 180.0
        let lat1 = from.latitude * .pi / 180.0
        let lon1 = from.longitude * .pi / 180.0

        let lat2 = asin(sin(lat1) * cos(distanceMeters / earthRadius) +
                       cos(lat1) * sin(distanceMeters / earthRadius) * cos(bearingRadians))

        let lon2 = lon1 + atan2(sin(bearingRadians) * sin(distanceMeters / earthRadius) * cos(lat1),
                               cos(distanceMeters / earthRadius) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(
            latitude: lat2 * 180.0 / .pi,
            longitude: lon2 * 180.0 / .pi
        )
    }

    private func calculateCrownOffset(screenHeight: CGFloat) {
        crownOffset = screenHeight * 0.01
    }
}

// MARK: - Club Distance Editor View

struct ClubDistanceEditorView: View {
    @ObservedObject var store: WatchDataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int = 0
    @State private var editingDistance: Double = 100
    @FocusState private var isCrownFocused: Bool

    // Get enabled clubs with their type names
    private var enabledClubs: [(club: ClubData, typeName: String)] {
        store.availableClubs.compactMap { club in
            guard let clubType = store.clubTypes.first(where: { $0.id == club.clubTypeId }) else {
                return nil
            }
            return (club, clubType.name)
        }
    }

    private var currentClubName: String {
        guard selectedIndex < enabledClubs.count else { return "" }
        return enabledClubs[selectedIndex].typeName
    }

    private var currentDistance: Int {
        Int(editingDistance.rounded())
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("Adjust Distances")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            // Club name
            Text(currentClubName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)

            // Distance display
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(currentDistance)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(.green)
                Text("yd")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            // Instructions
            Text("Crown: adjust distance")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            // Navigation buttons
            HStack(spacing: 20) {
                Button(action: previousClub) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(selectedIndex > 0 ? .white : .gray)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedIndex == 0)

                Button(action: nextClub) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(selectedIndex < enabledClubs.count - 1 ? .white : .gray)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedIndex >= enabledClubs.count - 1)
            }
            .padding(.top, 4)

            // Done button
            Button("Done") {
                saveCurrentDistance()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.top, 8)
        }
        .focusable()
        .focused($isCrownFocused)
        .digitalCrownRotation(
            $editingDistance,
            from: 10,
            through: 350,
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            isCrownFocused = true
            loadCurrentClubDistance()
        }
    }

    private func loadCurrentClubDistance() {
        guard selectedIndex < enabledClubs.count else { return }
        let typeName = enabledClubs[selectedIndex].typeName
        let average = ClubPredictionManager.shared.getAverage(
            for: typeName,
            mode: .manual,
            customAverages: store.customClubAverages
        )
        editingDistance = Double(average)
    }

    private func saveCurrentDistance() {
        guard selectedIndex < enabledClubs.count else { return }
        let typeName = enabledClubs[selectedIndex].typeName
        var averages = store.customClubAverages
        averages[typeName] = currentDistance
        store.customClubAverages = averages
    }

    private func previousClub() {
        guard selectedIndex > 0 else { return }
        saveCurrentDistance()
        selectedIndex -= 1
        loadCurrentClubDistance()
        WKInterfaceDevice.current().play(.click)
    }

    private func nextClub() {
        guard selectedIndex < enabledClubs.count - 1 else { return }
        saveCurrentDistance()
        selectedIndex += 1
        loadCurrentClubDistance()
        WKInterfaceDevice.current().play(.click)
    }
}

