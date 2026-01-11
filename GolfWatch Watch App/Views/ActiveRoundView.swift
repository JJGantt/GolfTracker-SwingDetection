import SwiftUI
import MapKit

struct ActiveRoundView: View {
    @StateObject private var store = WatchDataStore.shared
    @StateObject private var locationManager = LocationManager.shared
    @StateObject private var swingDetector = SwingDetectionManager.shared
    @StateObject private var workoutManager = WorkoutManager.shared
    @StateObject private var satelliteCache = WatchSatelliteCacheManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedClubIndex: Double = 0
    @State private var position: MapCameraPosition = .automatic
    @State private var showingRecordedFeedback = false
    @State private var capturedAimDirection: Double? = nil
    @State private var crownOffset: CGFloat = 0
    @State private var isPlacingTarget = false
    @State private var isPlacingPenalty = false
    @State private var temporaryPenaltyPosition: CLLocationCoordinate2D?
    @State private var showingActionsSheet = false
    @State private var showingEditHole = false
    @State private var showingAddHole = false
    @State private var showingAccelTest = false
    @State private var navigateToAddHole = false
    @State private var isLastStrokeViewMode = false
    @State private var undoHoldProgress: Double = 0.0
    @State private var undoHoldTimer: Timer?
    @State private var isPlacingHole = false
    @State private var temporaryHolePosition: CLLocationCoordinate2D?
    @State private var isFullViewMode = false
    @FocusState private var isMapFocused: Bool
    @FocusState private var isMainViewFocused: Bool

    private let clubs = Club.allCases

    private var selectedClub: Club {
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
        VStack {
            Spacer()
                .frame(height: crownOffset)
            HStack {
                Spacer()
                Text(selectedClub.rawValue)
                    .font(.system(size: clubFontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .padding(.trailing, 2)
            Spacer()
        }
        .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
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
                    .handGestureShortcut(.primaryAction)
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
        guard let capturedHeading = capturedAimDirection,
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
        let clubFontSize = geometry.size.width * 0.065

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
            through: Double(clubs.count - 1),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
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
        .sheet(isPresented: $showingAccelTest) {
            AccelTestView()
        }
        .navigationDestination(isPresented: $navigateToAddHole) {
            AddHoleNavigationView(store: store, locationManager: locationManager)
        }
        .onAppear {
            print("⌚ [ActiveRoundView] View appeared")
            print("⌚ [ActiveRoundView] Current location: \(locationManager.location?.description ?? "nil")")
            print("⌚ [ActiveRoundView] Authorization status: \(locationManager.authorizationStatus.rawValue)")
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
        .onChange(of: locationManager.heading) { _, _ in
            // Trigger view refresh when heading updates (to rotate user arrow)
        }
        .onChange(of: store.currentHoleIndex) { _, _ in
            // Watch syncs hole index from phone - update map when it changes
            updateMapPosition()
        }
        .onChange(of: store.currentHole) { _, _ in
            // Update map when hole changes (also covers new holes added from phone)
            updateMapPosition()
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

            // Calculate camera info for satellite view
            let bearing = calculateBearing(from: userLocation.coordinate, to: hole.coordinate)
            let holeLocation = CLLocation(latitude: hole.coordinate.latitude, longitude: hole.coordinate.longitude)
            let distance = userLocation.distance(from: holeLocation)
            let centerLat = userLocation.coordinate.latitude + (hole.coordinate.latitude - userLocation.coordinate.latitude) * 0.45
            let centerLon = userLocation.coordinate.longitude + (hole.coordinate.longitude - userLocation.coordinate.longitude) * 0.5

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
                isPlacingPenalty: isPlacingPenalty
            )
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

                // Stroke markers - show all strokes for current hole
                if let round = store.currentRound {
                    let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                if isFullViewMode {
                                    // Full view mode - white circles
                                    Circle()
                                        .fill(stroke.isPenalty ? .orange : .white)
                                        .frame(width: 12, height: 12)
                                        .opacity(0.9)
                                        .shadow(color: .black, radius: 2)
                                } else {
                                    // Default mode - numbered circles
                                    Circle()
                                        .fill(stroke.isPenalty ? .orange : .white)
                                        .frame(width: 20, height: 20)
                                        .opacity(0.85)
                                        .shadow(color: .black, radius: 2)

                                    Text("\(stroke.strokeNumber)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(stroke.isPenalty ? .white : .black)
                                }

                                // Show distance in full view mode or for last stroke in default mode
                                if isFullViewMode || (stroke.id == lastRealStroke?.id) {
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
                                                .offset(y: isFullViewMode ? -12 : -16)
                                            Spacer()
                                        }
                                        .frame(height: isFullViewMode ? 12 : 20)
                                    }
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

            // Middle row: Undo and Edit buttons
            HStack(spacing: 8) {
                // Undo button
                Button(action: {
                    deleteLastStroke()
                    showingActionsSheet = false
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

            // Third row: Full View and Satellite toggles
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
                }) {
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

            // Bottom row: Motion Test
            HStack(spacing: 8) {
                // Motion Test button
                Button(action: {
                    showingActionsSheet = false
                    showingAccelTest = true
                }) {
                    HStack(spacing: 6) {
                        Text("Motion Test")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.yellow.opacity(0.9))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 8)
        }
        .padding()
    }

    // MARK: - Actions

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

        // Capture the current heading
        capturedAimDirection = finalHeading
        print("⌚ [AimDirection] Captured heading: \(finalHeading)")

        // Haptic feedback
        WKInterfaceDevice.current().play(.click)
    }

    private func recordStroke() {
        // If no aim direction was captured, default to bearing towards the flag (if hole exists)
        var trajectoryHeading = capturedAimDirection
        if trajectoryHeading == nil,
           let userLocation = locationManager.location,
           let hole = store.currentHole {
            trajectoryHeading = calculateBearing(from: userLocation.coordinate, to: hole.coordinate)
            print("⌚ [RecordStroke] No captured heading, using bearing to flag: \(trajectoryHeading!)")
        }

        // Pass the trajectory heading to the stroke
        // This works even if there's no hole - addStroke will use the next hole number
        store.addStroke(club: selectedClub, trajectoryHeading: trajectoryHeading)

        // Reset aim direction after stroke is recorded
        capturedAimDirection = nil

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

        // Calculate trajectory heading if we have a captured aim direction
        var trajectoryHeading = capturedAimDirection
        if trajectoryHeading == nil {
            // Default to bearing towards the flag
            trajectoryHeading = calculateBearing(from: swing.location, to: hole.coordinate)
        }

        let stroke = Stroke(
            holeNumber: hole.number,
            strokeNumber: strokeNumber,
            coordinate: swing.location,
            club: selectedClub,
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

        // Reset aim direction after stroke is recorded
        capturedAimDirection = nil

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
            let strokesForHole = round.strokes.filter { $0.holeNumber == hole.number }
            let strokeNumber = strokesForHole.count + 1

            let stroke = Stroke(
                holeNumber: hole.number,
                strokeNumber: strokeNumber,
                coordinate: penaltyCoord,
                club: selectedClub,
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
        crownOffset = screenHeight * 0.05
    }
}

