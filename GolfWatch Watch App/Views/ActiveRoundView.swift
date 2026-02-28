import SwiftUI
import MapKit
import WatchKit

struct ActiveRoundView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var locationManager = LocationManager.shared
    @StateObject private var swingDetector = SwingDetectionManager.shared
    @StateObject private var workoutManager = WorkoutManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var selectedClubIndex: Double = 0
    @State private var position: MapCameraPosition = .automatic
    @State private var showingRecordedFeedback = false
    @State private var crownOffset: CGFloat = 0
    @State private var isPlacingTarget = false
    @State private var isPlacingPenalty = false
    @State private var temporaryPenaltyPosition: CLLocationCoordinate2D?
    @State private var showingOptions = false
    @State private var showingEditHole = false
    @State private var isLastStrokeViewMode = false
    @State private var undoHoldProgress: Double = 0.0
    @State private var undoHoldTimer: Timer?
    @State private var isFullViewMode = false
    @State private var isCrownScrolling = false
    @State private var crownScrollTimer: Timer?
    @State private var isPulsing = false
    @State private var showingDistanceEditor = false
    @State private var manualClubOverride = false       // True when user manually changed club
    @State private var onGreenOverride = false          // True when auto-switched to putter for current green
    @State private var navigateToAccelTest = false
    @State private var navigateToViewSettings = false
    @State private var navigateToClubRecommend = false
    @State private var navigateToPredictGreen = false
    @State private var isAutoSelectingClub = false      // True when we're programmatically updating club
    @State private var autoAddedStrokeId: UUID?          // Tracks the auto-added stroke for undo/club update
    @State private var lastAutoAddedLocation: CLLocationCoordinate2D?  // GPS of last auto-added stroke for practice replacement
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
           let round = store.currentRound {
            let previousHoleNumber = round.holes[store.currentHoleIndex - 1].number
            return round.isHoleCompleted(previousHoleNumber)
        }

        return false
    }

    private var currentHoleGreenBlob: HoleDetectionBlob? {
        guard let courseId = store.currentRound?.courseId,
              let holeCoord = store.currentHole?.coordinate else { return nil }
        return store.filteredGreenCandidates(for: courseId)
            .first { $0.contains(holeCoord) }
    }

    private var isOnCurrentGreen: Bool {
        guard let userCoord = locationManager.location?.coordinate,
              let blob = currentHoleGreenBlob else { return false }
        return blob.contains(userCoord)
    }

    private func putterClubIndex() -> Int? {
        clubs.indices.first { index in
            guard let clubType = store.clubTypes.first(where: { $0.id == clubs[index].clubTypeId }) else { return false }
            return clubType.name == "Putt"
        }
    }

    private var distanceToHole: Int? {
        guard let userLocation = locationManager.location,
              let hole = store.currentHole,
              let holeCoord = hole.coordinate else { return nil }

        let holeLocation = CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude)
        let distanceInMeters = userLocation.distance(from: holeLocation)
        return Int(distanceInMeters * 1.09361)
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
            holeNumber = round.holes.count + 1
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
        // On watchOS 10, club selector is integrated into buttonsOverlay instead
        if #available(watchOS 11.0, *) {
            if clubs.isEmpty {
                Text("No Clubs")
                    .font(.system(size: clubFontSize, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                clubSelectorOverlayModern(clubFontSize: clubFontSize)
            }
        }
        // watchOS 10: club selector is shown in buttonsOverlay via legacyClubSelector()
    }

    // MARK: - watchOS 11+ Club Selector (crown-based with expanding clubs)
    @available(watchOS 11.0, *)
    @ViewBuilder
    private func clubSelectorOverlayModern(clubFontSize: CGFloat) -> some View {
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
        let adjacent1Size = clubFontSize * 0.8
        let adjacent2Size = clubFontSize * 0.65

        let adjacent1Height: CGFloat = adjacent1Size + 8
        let adjacent2Height: CGFloat = adjacent2Size + 4

        VStack {
            Spacer()
                .frame(height: crownOffset)
            HStack {
                Spacer()

                ZStack {
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

                    if isCrownScrolling {
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

                    if isCrownScrolling {
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
    }

    // MARK: - watchOS 10 Club Selector (inline in button stack)
    @ViewBuilder
    private func legacyClubSelector(buttonSize: CGFloat) -> some View {
        let currentIndex = Int(selectedClubIndex.rounded()) % clubs.count
        let iconSize: CGFloat = buttonSize * 0.45

        VStack(spacing: 4) {
            // Up arrow button - previous club
            Button(action: {
                if currentIndex > 0 {
                    selectedClubIndex = Double(currentIndex - 1)
                    WKInterfaceDevice.current().play(.click)
                }
            }) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.9)
                        .frame(width: buttonSize, height: buttonSize)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                    Image(systemName: "chevron.up")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundColor(currentIndex > 0 ? .white : .white.opacity(0.3))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(currentIndex <= 0)

            // Current club name - tap to re-enable auto-selection
            Text(selectedClub.map { store.getTypeName(for: $0) } ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(manualClubOverride ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.blue.opacity(0.7)))
                        .opacity(0.9)
                )
                .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                .onTapGesture {
                    if manualClubOverride {
                        manualClubOverride = false
                        WKInterfaceDevice.current().play(.click)
                    }
                }

            // Down arrow button - next club
            Button(action: {
                if currentIndex < clubs.count - 1 {
                    selectedClubIndex = Double(currentIndex + 1)
                    WKInterfaceDevice.current().play(.click)
                }
            }) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.9)
                        .frame(width: buttonSize, height: buttonSize)
                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundColor(currentIndex < clubs.count - 1 ? .white : .white.opacity(0.3))
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(currentIndex >= clubs.count - 1)
        }
    }

    @ViewBuilder
    private func buttonsOverlay(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: 4) {
                // Left: Target button
                VStack(spacing: 4) {
                    // Target button - hide when placing penalty or no hole
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
                        .focusable(false)
                    }
                }

                // Invisible heading toggle button in center (between left and right stacks)
                // Positioned slightly higher to avoid pull-up menu at bottom
                // Hidden when swing detected overlay is showing to avoid hit area overlap with dismiss button
                if store.currentHole != nil && swingDetector.lastDetectedSwing == nil && !isPlacingTarget && !isPlacingPenalty {
                    VStack {
                        Spacer()
                        Button(action: toggleAimDirection) {
                            Rectangle()
                                .fill(Color.white.opacity(0.001)) // Near-invisible but tappable
                                .frame(maxWidth: .infinity)
                                .frame(height: buttonSize * 2 + 4) // Height of two buttons + spacing
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .focusable(false)
                        .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false)
                        Spacer()
                            .frame(height: buttonSize * 0.5) // Extra padding at bottom
                    }
                } else {
                    Spacer()
                }

                // Right side column
                VStack(spacing: 4) {
                    // watchOS 10: Club selector above the buttons
                    if #unavailable(watchOS 11.0) {
                        if !clubs.isEmpty {
                            legacyClubSelector(buttonSize: buttonSize)
                        }
                    }

                    // Stroke button
                    VStack(spacing: 4) {
                        // Green stroke button - always show
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
                        .focusable(false)
                        .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false)
                        .opacity(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false ? 0.3 : 0.95)
                    }
                }
                .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
            }
            .padding(.horizontal, 4)
            .modifier(ButtonsBottomPaddingModifier())
        }
        .ignoresSafeArea()
    }

    private func swingTypeColor(_ swing: SwingDetectionManager.DetectedSwing?) -> Color {
        guard let swing = swing else { return .cyan }
        switch swing.swingType {
        case .putt: return .cyan
        case .swing: return .orange
        }
    }

    private func swingTypeLabel(_ swing: SwingDetectionManager.DetectedSwing?) -> String {
        guard let swing = swing else { return "" }
        switch swing.swingType {
        case .putt: return "PUTT"
        case .swing: return "SWING"
        }
    }

    @ViewBuilder
    private func swingDetectedOverlay(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        if let swing = swingDetector.lastDetectedSwing, store.currentHole != nil && !isPlacingTarget && !isPlacingPenalty {
            let typeColor = swingTypeColor(swing)
            VStack(spacing: 4) {
                // Main swing button - add stroke (manual) or undo (auto_add)
                Button(action: { swingDetector.autoAdd ? undoAutoAddedStroke() : addStrokeFromLastSwing() }) {
                    ZStack {
                        // Outer pulse ring for motion effect
                        Circle()
                            .stroke(typeColor.opacity(0.3), lineWidth: 2)
                            .frame(width: buttonSize * 1.7, height: buttonSize * 1.7)
                            .scaleEffect(isPulsing ? 1.18 : 0.92)
                            .opacity(isPulsing ? 0.0 : 0.8)
                            .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false),
                                       value: isPulsing)

                        Circle()
                            .fill(typeColor.opacity(0.7))
                            .frame(width: buttonSize * 1.5, height: buttonSize * 1.5)
                            .shadow(color: typeColor.opacity(0.4), radius: 8, x: 0, y: 0)

                        if swingDetector.autoAdd {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: iconSize * 1.4, weight: .bold))
                                .foregroundColor(.white)
                        } else {
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
                }
                .buttonStyle(PlainButtonStyle())
                .focusable(false)
                .onAppear {
                    // This single change starts the forever animation.
                    isPulsing = true
                }
                .onDisappear {
                    // Optional: helps if the view reappears and you want it to restart cleanly.
                    isPulsing = false
                }

                // Dismiss button - smaller X below; in auto_add mode, saves current club to the stroke
                Button(action: {
                    if swingDetector.autoAdd, let strokeId = autoAddedStrokeId, let club = selectedClub {
                        store.updateStrokeClub(strokeId: strokeId, clubId: club.id)
                        autoAddedStrokeId = nil
                    }
                    swingDetector.clearLastSwing()
                    WKInterfaceDevice.current().play(.click)
                    isMainViewFocused = true
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
                .focusable(false)

                // Swing type label
                Text(swingTypeLabel(swing))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(typeColor)
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
                        showingOptions = true
                    }

                Spacer()
            }
        }
        .ignoresSafeArea()
        .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
    }

    @ViewBuilder
    private func penaltyPlacementButtons(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom) {
                // Cancel button (left)
                Button(action: {
                    isPlacingPenalty = false
                    temporaryPenaltyPosition = nil
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
                .focusable(false)

                Spacer()

                // Confirm button (right) - only show when position is placed
                if temporaryPenaltyPosition != nil {
                    Button(action: confirmPenaltyPlacement) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.95))
                                .frame(width: buttonSize, height: buttonSize)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                            Image(systemName: "checkmark")
                                .font(.system(size: iconSize, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .focusable(false)
                }
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
                }
                // No else case - when no hole exists, onAppear navigates to HolePlacementView
            }
            .padding(.leading, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ignoresSafeArea()
        .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
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
                // No hole defined - show map centered on user (briefly, before navigating to AddHoleNavigationView)
                noHoleMapView()
                    .ignoresSafeArea()
            }

            // Club selector overlay (positioned at crown height)
            clubSelectorOverlay(clubFontSize: clubFontSize)

            // Info overlay (top left) - distance and hole info
            holeInfoOverlay

            // Buttons overlay (bottom)
            buttonsOverlay(buttonSize: buttonSize, iconSize: iconSize)

            // Swing detected overlay (centered)
            swingDetectedOverlay(buttonSize: buttonSize, iconSize: iconSize)

            // Bottom swipe-up indicator
            swipeUpIndicator

            // Buttons for penalty placement (cancel left, confirm right)
            if isPlacingPenalty {
                penaltyPlacementButtons(buttonSize: buttonSize, iconSize: iconSize)
            }

            // Invisible button for double-tap gesture (clench fingers twice)
            // Uses detected swing if available, otherwise adds regular stroke
            Button(action: handleDoubleTapGesture) {
                Color.clear
                    .frame(width: 1, height: 1)
            }
            .buttonStyle(PlainButtonStyle())
            .modifier(HandGestureShortcutModifier())
            .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false || isPlacingTarget || isPlacingPenalty)
        }
        .task {
            calculateCrownOffset(screenHeight: geometry.size.height)
        }
    }

    /// Whether the current hole needs its flag location to be set
    private var needsFlagPlacement: Bool {
        guard let hole = store.currentHole else { return false }
        return !hole.hasLocation
    }

    var body: some View {
        Group {
            if needsFlagPlacement, let hole = store.currentHole {
                // Current hole exists but has no flag location - show placement view
                HolePlacementView(store: store, locationManager: locationManager, hole: hole, isEditing: false)
            } else {
                // Normal active round view
                GeometryReader { geometry in
                    mainContent(geometry: geometry)
                }
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
                .focusable()
                .focused($isMainViewFocused)
                .modifier(ClubCrownRotationModifier(selectedClubIndex: $selectedClubIndex, clubCount: clubs.count))
                .digitalCrownAccessory(.hidden)
            }
        }
        .sheet(isPresented: $showingOptions) {
            OptionsView(
                store: store,
                showingOptions: $showingOptions,
                showingEditHole: $showingEditHole,
                showingDistanceEditor: $showingDistanceEditor,
                isFullViewMode: $isFullViewMode,
                manualClubOverride: $manualClubOverride,
                navigateToAccelTest: $navigateToAccelTest,
                navigateToViewSettings: $navigateToViewSettings,
                navigateToClubRecommend: $navigateToClubRecommend,
                navigateToPredictGreen: $navigateToPredictGreen,
                isPlacingPenalty: $isPlacingPenalty,
                updateMapPosition: updateMapPosition,
                updateNoHoleMapPosition: updateNoHoleMapPosition,
                deleteLastStroke: deleteLastStroke,
                dismissParent: { dismiss() },
                canUndo: canUndo
            )
        }
        .sheet(isPresented: $showingEditHole) {
            if let hole = store.currentHole {
                HolePlacementView(store: store, locationManager: locationManager, hole: hole, isEditing: true)
            }
        }
        .sheet(isPresented: $showingDistanceEditor) {
            ClubDistanceEditorView(store: store)
        }
        .sheet(isPresented: $navigateToAccelTest) {
            AccelTestView()
        }
        .sheet(isPresented: $navigateToViewSettings) {
            ViewSettingsView(
                isFullViewMode: $isFullViewMode,
                updateMapPosition: updateMapPosition,
                updateNoHoleMapPosition: updateNoHoleMapPosition,
                hasCurrentHole: store.currentHole != nil
            )
        }
        .sheet(isPresented: $navigateToClubRecommend) {
            ClubRecommendSettingsView(
                store: store,
                manualClubOverride: $manualClubOverride,
                showingDistanceEditor: $showingDistanceEditor
            )
        }
        .sheet(isPresented: $navigateToPredictGreen) {
            PredictGreenSettingsView(store: store)
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

            // Push selected club type to detector for smart_detect
            updateSwingDetectorClub()

            // Request HealthKit authorization and start workout if there's an active round
            if store.currentRound != nil && !workoutManager.isWorkoutActive {
                workoutManager.requestAuthorization { success, _ in
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
            // Don't stop motion monitoring here - onDisappear fires when pushing
            // to child views (e.g. AccelTestView) on watchOS, which would kill
            // motion updates. Monitoring continues while the round is active,
            // same as the workout. It gets stopped via stopMonitoring() when needed.
            // Clean up crown scroll timer
            crownScrollTimer?.invalidate()
        }
        .onChange(of: locationManager.location) { _, _ in
            // Trigger view refresh when location updates (for distance display)
            // Also update map orientation to keep user at bottom, flag at top
            if !isPlacingTarget {
                updateMapPosition()
            }

            // Auto-switch to putter when stepping onto current hole's green
            guard store.clubPredictionMode != .off else { return }
            let nowOnGreen = isOnCurrentGreen
            if nowOnGreen && !onGreenOverride && !manualClubOverride {
                if let putterIndex = putterClubIndex() {
                    onGreenOverride = true
                    isAutoSelectingClub = true
                    selectedClubIndex = Double(putterIndex)
                    updateSwingDetectorClub()
                    isAutoSelectingClub = false
                }
            } else if !nowOnGreen && onGreenOverride {
                onGreenOverride = false
                // Re-run distance prediction if user hasn't manually overridden
                if !manualClubOverride, let distance = distanceToHole,
                   let predictedIndex = ClubPredictionManager.shared.predictClubIndex(
                       forDistance: distance,
                       clubs: clubs,
                       clubTypes: store.clubTypes,
                       mode: store.clubPredictionMode,
                       customAverages: store.customClubAverages,
                       disabledClubs: store.disabledPredictionClubs
                   ) {
                    isAutoSelectingClub = true
                    selectedClubIndex = Double(predictedIndex)
                    updateSwingDetectorClub()
                    isAutoSelectingClub = false
                }
            }
        }
        .onChange(of: distanceToHole) { _, newDistance in
            // Auto-predict club based on distance if enabled and not manually overridden
            guard !manualClubOverride,
                  !onGreenOverride,
                  store.clubPredictionMode != .off,
                  let distance = newDistance else { return }

            if let predictedIndex = ClubPredictionManager.shared.predictClubIndex(
                forDistance: distance,
                clubs: clubs,
                clubTypes: store.clubTypes,
                mode: store.clubPredictionMode,
                customAverages: store.customClubAverages,
                disabledClubs: store.disabledPredictionClubs
            ) {
                isAutoSelectingClub = true
                selectedClubIndex = Double(predictedIndex)
                updateSwingDetectorClub()
                isAutoSelectingClub = false
            }
        }
        .onChange(of: store.currentHoleIndex) { _, _ in
            // Watch syncs hole index from phone - update map when it changes
            manualClubOverride = false  // Reset manual override on hole change
            onGreenOverride = false
            lastAutoAddedLocation = nil
            autoAddedStrokeId = nil
            updateMapPosition()
        }
        .onChange(of: store.currentHole) { _, _ in
            // Update map when hole changes (also covers new holes added from phone)
            updateMapPosition()
        }
        .onChange(of: showingOptions) { _, isShowing in
            // When actions sheet closes, restore focus to main view (unless entering penalty mode)
            if !isShowing && !isPlacingPenalty {
                isMainViewFocused = true
            }
        }
        .onChange(of: isPlacingPenalty) { _, isPlacing in
            // Handle focus when entering/exiting penalty placement mode
            if isPlacing {
                isMapFocused = true
                isMainViewFocused = false
            } else {
                isMapFocused = false
                isMainViewFocused = true
                updateMapPosition()
            }
        }
        .onChange(of: swingDetector.lastDetectedSwing?.timestamp) { _, newValue in
            // Auto-select putter when putt detected within range and putter not already selected
            if let swing = swingDetector.lastDetectedSwing,
               swing.swingType == .putt,
               swingDetector.puttAutoSelectYards > 0,
               swingDetector.selectedClubTypeName != "Putt",
               let distance = distanceToHole,
               distance <= swingDetector.puttAutoSelectYards,
               let putterIndex = putterClubIndex() {
                isAutoSelectingClub = true
                selectedClubIndex = Double(putterIndex)
                updateSwingDetectorClub()
                isAutoSelectingClub = false
            }
            // Auto-add stroke when a new swing is detected and autoAdd is on
            if swingDetector.autoAdd, newValue != nil {
                autoAddStrokeFromSwing()
            }
        }
        .onChange(of: selectedClubIndex) { _, _ in
            // Detect manual club change (user scrolling vs auto-prediction)
            if !isAutoSelectingClub && store.clubPredictionMode != .off {
                manualClubOverride = true
            }

            // Push selected club type to detector for smart_detect
            updateSwingDetectorClub()

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
        standardMapView(for: hole)
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
                if let round = store.currentRound {
                    let nextHoleNumber = round.holes.count + 1
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

            }
            .modifier(HideMapControlsModifier(isInteractive: false))
        }
        .onAppear {
            updateNoHoleMapPosition()
        }
    }

    @ViewBuilder
    private func standardMapView(for hole: Hole) -> some View {
        // Note: This view is only called when hole.hasLocation is true (via needsFlagPlacement check)
        let holeCoord = hole.coordinate!
        MapReader { proxy in
            Map(position: $position) {
                // Hole marker (top) - green if completed, yellow if not
                Annotation("", coordinate: holeCoord) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 20))
                        .foregroundColor(store.isHoleCompleted(hole.number) ? .green : .yellow)
                }

                // User location (bottom) - shows frozen state with white outline
                if let userLocation = locationManager.location {
                    Annotation("", coordinate: userLocation.coordinate) {
                        let isFrozen = swingDetector.capturedAimDirection != nil
                        let bearingToHole = calculateBearing(from: userLocation.coordinate, to: holeCoord)
                        let relativeHeading: Double = {
                            // If frozen, use captured direction; otherwise use live heading
                            if let capturedHeading = swingDetector.capturedAimDirection {
                                return (capturedHeading - bearingToHole + 360).truncatingRemainder(dividingBy: 360)
                            }
                            guard let heading = locationManager.heading else { return 0 }
                            // Map is rotated by bearing to hole, so arrow needs to compensate
                            return (heading - bearingToHole + 360).truncatingRemainder(dividingBy: 360)
                        }()

                        ZStack {
                            // White outline when frozen
                            if isFrozen {
                                Circle()
                                    .stroke(Color.white, lineWidth: 2)
                                    .frame(width: 28, height: 28)
                            }

                            Image(systemName: "location.north.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                                .rotationEffect(.degrees(relativeHeading))
                                .shadow(color: .white, radius: 2)
                                .shadow(color: .black.opacity(0.3), radius: 1)
                        }
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
            .modifier(HideMapControlsModifier(isInteractive: isPlacingTarget || isPlacingPenalty))
            .allowsHitTesting(isPlacingTarget || isPlacingPenalty)
            .focusable(isPlacingTarget || isPlacingPenalty)
            .focused($isMapFocused)
            .onTapGesture { screenLocation in
                guard let coordinate = proxy.convert(screenLocation, from: .local) else { return }

                if isPlacingTarget {
                    var coords = targetCoordinatesBinding.wrappedValue
                    let tappedLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

                    // Calculate deletion radius dynamically based on zoom level
                    // Convert a 30pt screen radius to meters at the current zoom
                    let tapPixelRadius: CGFloat = 30
                    let offsetPoint = CGPoint(x: screenLocation.x + tapPixelRadius, y: screenLocation.y)
                    let deletionRadius: Double
                    if let offsetCoord = proxy.convert(offsetPoint, from: .local) {
                        let offsetLocation = CLLocation(latitude: offsetCoord.latitude, longitude: offsetCoord.longitude)
                        deletionRadius = max(tappedLocation.distance(from: offsetLocation), 6.0)
                    } else {
                        deletionRadius = 6.0 // fallback
                    }
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

    // MARK: - Actions

    private func applyClubPrediction() {
        guard store.clubPredictionMode != .off,
              let distance = distanceToHole else { return }
        if let predictedIndex = ClubPredictionManager.shared.predictClubIndex(
            forDistance: distance,
            clubs: clubs,
            clubTypes: store.clubTypes,
            mode: store.clubPredictionMode,
            customAverages: store.customClubAverages,
            disabledClubs: store.disabledPredictionClubs
        ) {
            isAutoSelectingClub = true
            selectedClubIndex = Double(predictedIndex)
            updateSwingDetectorClub()
            isAutoSelectingClub = false
        }
    }

    private func updateSwingDetectorClub() {
        guard let club = selectedClub else { return }
        let newTypeName = store.getTypeName(for: club)
        swingDetector.selectedClubTypeName = newTypeName
    }

    private func toggleAimDirection() {
        print("⌚ [AimDirection] User icon tapped")

        // If already frozen, unfreeze
        if swingDetector.capturedAimDirection != nil {
            print("⌚ [AimDirection] Unfreezing heading")
            swingDetector.capturedAimDirection = nil
            WKInterfaceDevice.current().play(.click)
            isMainViewFocused = true
            return
        }

        // Otherwise, capture current heading
        print("⌚ [AimDirection] Current heading: \(locationManager.heading?.description ?? "nil")")

        var heading: Double?

        // Try to get real heading first
        if let realHeading = locationManager.heading {
            heading = realHeading
        } else if let userLocation = locationManager.location,
                  let hole = store.currentHole,
                  let holeCoord = hole.coordinate {
            // Fallback: Use bearing to hole + 45 degrees as simulated offset
            // This allows testing in simulator
            let bearingToHole = calculateBearing(from: userLocation.coordinate, to: holeCoord)
            heading = (bearingToHole + 45).truncatingRemainder(dividingBy: 360)
            print("⌚ [AimDirection] Using simulated heading (bearing + 45°)")
        }

        guard let finalHeading = heading else {
            // No heading available, vibrate to indicate error
            print("⌚ [AimDirection] ERROR: No heading or location available")
            WKInterfaceDevice.current().play(.failure)
            isMainViewFocused = true
            return
        }

        // Capture the current heading in SwingDetectionManager so it persists with detected swings
        swingDetector.capturedAimDirection = finalHeading
        print("⌚ [AimDirection] Captured heading: \(finalHeading)")

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)
        isMainViewFocused = true
    }

    private func recordStroke() {
        // If no aim direction was captured, default to bearing towards the flag (if hole exists)
        var trajectoryHeading = swingDetector.capturedAimDirection
        if trajectoryHeading == nil,
           let userLocation = locationManager.location,
           let hole = store.currentHole,
           let holeCoord = hole.coordinate {
            trajectoryHeading = calculateBearing(from: userLocation.coordinate, to: holeCoord)
            print("⌚ [RecordStroke] No captured heading, using bearing to flag: \(trajectoryHeading!)")
        }

        // Pass the trajectory heading to the stroke
        // This works even if there's no hole - addStroke will use the next hole number
        guard let club = selectedClub else {
            print("⌚ [RecordStroke] ERROR: No club selected")
            return
        }
        store.addStroke(clubId: club.id, trajectoryHeading: trajectoryHeading)

        // Reset manual club override and immediately re-predict based on current distance
        manualClubOverride = false
        applyClubPrediction()

        // Reset aim direction after stroke is recorded
        swingDetector.capturedAimDirection = nil

        // Haptic feedback
        WKInterfaceDevice.current().play(.success)
        isMainViewFocused = true

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
        if swingDetector.lastDetectedSwing != nil && store.currentHole != nil {
            if swingDetector.autoAdd {
                undoAutoAddedStroke()
            } else {
                addStrokeFromLastSwing()
            }
        } else {
            recordStroke()
        }
    }

    private func addStrokeFromLastSwing() {
        guard let swing = swingDetector.lastDetectedSwing else {
            print("⌚ [AddLastSwing] No swing detected")
            return
        }

        guard store.currentRound != nil, let hole = store.currentHole else {
            print("⌚ [AddLastSwing] No active round or hole")
            return
        }

        // Use aim direction captured at swing detection time, fall back to bearing towards flag
        var trajectoryHeading = swing.trajectoryHeading
        if trajectoryHeading == nil, let holeCoord = hole.coordinate {
            trajectoryHeading = calculateBearing(from: swing.location, to: holeCoord)
        }

        guard let club = selectedClub else {
            print("⌚ [RecordStrokeFromMotion] ERROR: No club selected")
            return
        }

        let strokeId = store.addStroke(
            clubId: club.id,
            trajectoryHeading: trajectoryHeading,
            coordinate: swing.location,
            acceleration: swing.peakAcceleration
        )

        if let strokeId = strokeId, let meta = swingDetector.lastDetectionMetadata {
            swingDetector.cacheDetectionMetadata(strokeId: strokeId, metadata: meta)
        }

        manualClubOverride = false
        applyClubPrediction()
        swingDetector.capturedAimDirection = nil
        swingDetector.clearLastSwing()

        WKInterfaceDevice.current().play(.success)
        isMainViewFocused = true

        print("⌚ [AddLastSwing] Added stroke from detected swing at \(swing.location) with \(swing.peakAcceleration)G")
    }

    /// Auto-add a stroke from the detected swing without clearing the overlay.
    /// Called by onChange when autoAdd is enabled.
    /// When ignorePractice is ON and the swing type is not putt, replaces the previous
    /// auto-added stroke if the user hasn't moved (within ignorePracticeRadius yards).
    private func autoAddStrokeFromSwing() {
        guard let swing = swingDetector.lastDetectedSwing else { return }
        guard store.currentRound != nil, let hole = store.currentHole else { return }
        guard !store.isHoleCompleted(hole.number) else { return }

        var trajectoryHeading = swing.trajectoryHeading
        if trajectoryHeading == nil, let holeCoord = hole.coordinate {
            trajectoryHeading = calculateBearing(from: swing.location, to: holeCoord)
        }

        guard let club = selectedClub else { return }

        // Practice swing replacement: delete previous auto-added stroke if same location
        if autoAddedStrokeId != nil,
           let prevLoc = lastAutoAddedLocation,
           swingDetector.shouldReplacePreviousStroke(
               newLocation: swing.location,
               previousLocation: prevLoc,
               swingType: swing.swingType
           ) {
            store.deleteLastStroke()
            print("⌚ [AutoAdd] Replaced previous stroke (practice swing, same location)")
        }

        let strokeId = store.addStroke(
            clubId: club.id,
            trajectoryHeading: trajectoryHeading,
            coordinate: swing.location,
            acceleration: swing.peakAcceleration
        )

        if let strokeId = strokeId, let meta = swingDetector.lastDetectionMetadata {
            swingDetector.cacheDetectionMetadata(strokeId: strokeId, metadata: meta)
        }

        manualClubOverride = false
        applyClubPrediction()
        swingDetector.capturedAimDirection = nil
        autoAddedStrokeId = strokeId
        lastAutoAddedLocation = swing.location

        // Same feedback as normal add
        WKInterfaceDevice.current().play(.success)

        print("⌚ [AutoAdd] Auto-added stroke from detected swing at \(swing.location)")
    }

    /// Undo the most recently auto-added stroke and dismiss the overlay.
    private func undoAutoAddedStroke() {
        if let strokeId = autoAddedStrokeId {
            swingDetector.logUndoEvent(strokeId: strokeId)
            store.deleteLastStroke()
            autoAddedStrokeId = nil
            print("⌚ [AutoAdd] Undid auto-added stroke (false detection)")
        }
        swingDetector.clearLastSwing()
        WKInterfaceDevice.current().play(.click)
        isMainViewFocused = true
    }

    private func deleteLastStroke() {
        store.deleteLastStroke()

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)
    }

    private func confirmPenaltyPlacement() {
        guard let penaltyCoord = temporaryPenaltyPosition,
              store.currentRound != nil,
              store.currentHole != nil else { return }

        guard let club = selectedClub else {
            print("⌚ [ConfirmPenalty] ERROR: No club selected")
            return
        }

        store.addStroke(clubId: club.id, coordinate: penaltyCoord, isPenalty: true)

        WKInterfaceDevice.current().play(.failure)

        isPlacingPenalty = false
        temporaryPenaltyPosition = nil
    }

    private func finishCurrentHole() {
        // Check if this is the last hole before finishing
        let isLastHole: Bool = {
            guard let round = store.currentRound else { return false }
            return store.currentHoleIndex >= round.holes.count - 1
        }()

        store.finishCurrentHole()

        // Haptic feedback - directionUp for hole completion
        WKInterfaceDevice.current().play(.directionUp)

        // If this was the last hole, automatically add next hole (which will show flag placement)
        if isLastHole {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                store.addNextHole()
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

    private func updateMapPosition() {
        // Don't update map during target placement mode
        guard !isPlacingTarget else { return }

        guard let hole = store.currentHole,
              let holeCoord = hole.coordinate else { return }

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

    private func calculateCrownOffset(screenHeight: CGFloat) {
        crownOffset = screenHeight * 0.1
    }
}

// MARK: - Club Distance Editor View

struct ClubDistanceEditorView: View {
    @ObservedObject var store: WatchDataStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int = 0
    @State private var editingDistance: Double = 100
    @FocusState private var isCrownFocused: Bool

    // Get enabled clubs with their type names (excludes clubs not eligible for prediction)
    private var enabledClubs: [(club: ClubData, typeName: String)] {
        store.availableClubs.compactMap { club in
            guard let clubType = store.clubTypes.first(where: { $0.id == club.clubTypeId }) else {
                return nil
            }
            guard !ClubPredictionManager.excludedFromPrediction.contains(clubType.name) else {
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

    private var isCurrentClubDisabled: Bool {
        guard selectedIndex < enabledClubs.count else { return false }
        return store.disabledPredictionClubs.contains(enabledClubs[selectedIndex].typeName)
    }

    var body: some View {
        VStack(spacing: 6) {
            Spacer()
                .frame(height: 10)

            Text("Adjust Distances")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            // Club navigation with name between arrows
            HStack(spacing: 16) {
                Button(action: previousClub) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(selectedIndex > 0 ? .white : .gray.opacity(0.4))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedIndex == 0)

                Text(currentClubName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 60)

                Button(action: nextClub) {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(selectedIndex < enabledClubs.count - 1 ? .white : .gray.opacity(0.4))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(selectedIndex >= enabledClubs.count - 1)
            }

            // Distance display
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(currentDistance)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(isCurrentClubDisabled ? .gray : .green)
                Text("yd")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            // Instructions
            Text("Use crown to adjust distance")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            // Disable from predictions toggle
            Button(action: toggleClubDisabled) {
                HStack(spacing: 4) {
                    Image(systemName: isCurrentClubDisabled ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                    Text(isCurrentClubDisabled ? "Disabled from predictions" : "Enabled for predictions")
                        .font(.system(size: 11))
                }
                .foregroundColor(isCurrentClubDisabled ? .red : .green)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 4)
        }
        .focusable()
        .focused($isCrownFocused)
        .modifier(DistanceCrownRotationModifier(distance: $editingDistance))
        .onAppear {
            isCrownFocused = true
            loadCurrentClubDistance()
        }
        .onDisappear {
            saveCurrentDistance()
        }
    }

    private func loadCurrentClubDistance() {
        guard selectedIndex < enabledClubs.count else { return }
        let club = enabledClubs[selectedIndex].club
        guard let clubType = store.clubTypes.first(where: { $0.id == club.clubTypeId }) else { return }
        let average = ClubPredictionManager.shared.getAverage(
            for: clubType,
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

    private func toggleClubDisabled() {
        guard selectedIndex < enabledClubs.count else { return }
        let typeName = enabledClubs[selectedIndex].typeName
        if store.disabledPredictionClubs.contains(typeName) {
            store.disabledPredictionClubs.remove(typeName)
        } else {
            store.disabledPredictionClubs.insert(typeName)
        }
        WKInterfaceDevice.current().play(.click)
    }
}
