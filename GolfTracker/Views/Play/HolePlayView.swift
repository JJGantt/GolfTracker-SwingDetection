import SwiftUI
import MapKit

struct HolePlayView: View {
    @ObservedObject var store: DataStore
    let course: Course
    let resumingRound: Round?

    // MARK: - Core State
    @StateObject private var locationManager = LocationManager()
    @State private var currentHoleIndex = 0
    @State private var activeRound: Round?

    // MARK: - Map State
    @State private var position = MapCameraPosition.automatic
    @State private var useStandardMap = false
    @State private var savedMapRegion: MKCoordinateRegion?

    // MARK: - Editing Modes
    @State private var isAddingHole = false
    @State private var isMovingHoleManually = false
    @State private var isMovingStroke = false
    @State private var isAddingPenaltyStroke = false
    @State private var hasUserInteractedWithAddHoleMap = false

    // MARK: - Temporary Positions
    @State private var temporaryHolePosition: CLLocationCoordinate2D?
    @State private var temporaryPosition: CLLocationCoordinate2D?
    @State private var strokeToMove: Stroke?

    // MARK: - Dialogs & Sheets
    @State private var showingMoveHoleConfirmation = false
    @State private var showingClubSelection = false
    @State private var showingStrokeDetails = false
    @State private var showingCourseEditor = false

    // MARK: - Input State
    @State private var selectedStrokeIndex: Int = 0

    // MARK: - Stroke Recording
    @State private var trajectoryHeading: Double? = nil

    // MARK: - Target Placement
    @State private var isPlacingTarget = false
    @State private var isDeleting = false

    // MARK: - Initialization
    init(store: DataStore, course: Course, resumingRound: Round? = nil, startingHoleNumber: Int? = nil) {
        self.store = store
        self.course = course
        self.resumingRound = resumingRound
        if let holeNumber = startingHoleNumber {
            _currentHoleIndex = State(initialValue: holeNumber - 1)
        }
    }

    // MARK: - Computed Properties
    private var currentCourse: Course {
        store.courses.first { $0.id == course.id } ?? course
    }

    private var currentHole: Hole? {
        guard currentHoleIndex < currentCourse.holes.count else { return nil }
        return currentCourse.holes[currentHoleIndex]
    }

    private var currentRound: Round? {
        guard let activeRound = activeRound else { return nil }
        return store.rounds.first { $0.id == activeRound.id }
    }

    private var strokeCountForCurrentHole: Int {
        guard let round = currentRound,
              let hole = currentHole else { return 0 }
        return round.strokes.filter { $0.holeNumber == hole.number }.count
    }

    private var strokesForCurrentHole: [Stroke] {
        guard let round = currentRound,
              let hole = currentHole else { return [] }
        return round.strokes
            .filter { $0.holeNumber == hole.number }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var mostRecentStroke: Stroke? {
        return strokesForCurrentHole.last
    }

    private var effectiveTrajectoryHeading: Double? {
        // If user has set a trajectory, use it; otherwise default to heading toward hole
        if let heading = trajectoryHeading {
            return heading
        }

        // Calculate heading toward hole from user location
        guard let userLocation = locationManager.location,
              let hole = currentHole,
              let holeCoord = hole.coordinate else { return nil }

        let userCoord = userLocation.coordinate
        return MapCalculations.calculateBearing(from: userCoord, to: holeCoord)
    }

    private var selectedStroke: Stroke? {
        guard selectedStrokeIndex < strokesForCurrentHole.count else { return nil }
        return strokesForCurrentHole[selectedStrokeIndex]
    }

    private var isCurrentHoleCompleted: Bool {
        guard let round = currentRound,
              let hole = currentHole else { return false }
        return round.isHoleCompleted(hole.number)
    }

    private var canUndo: Bool {
        guard activeRound != nil else { return false }

        // Can undo if there are strokes on current hole
        if !strokesForCurrentHole.isEmpty {
            return true
        }

        // Can undo if we just finished the previous hole (no strokes on current, previous is completed)
        if currentHoleIndex > 0,
           let round = currentRound {
            let previousHoleNumber = currentCourse.holes[currentHoleIndex - 1].number
            return round.isHoleCompleted(previousHoleNumber)
        }

        return false
    }

    private var targetCoordinatesBinding: Binding<[CLLocationCoordinate2D]> {
        Binding(
            get: {
                guard let round = self.currentRound,
                      let hole = self.currentHole else { return [] }
                return round.targets
                    .filter { $0.holeNumber == hole.number }
                    .map { $0.coordinate }
            },
            set: { newCoordinates in
                guard let round = self.activeRound,
                      let hole = self.currentHole else { return }

                // Remove old targets for this hole
                var updatedRound = self.store.rounds.first { $0.id == round.id } ?? round
                updatedRound.targets.removeAll { $0.holeNumber == hole.number }

                // Add new targets
                let newTargets = newCoordinates.map { Target(holeNumber: hole.number, coordinate: $0) }
                updatedRound.targets.append(contentsOf: newTargets)

                // Update in store
                if let index = self.store.rounds.firstIndex(where: { $0.id == round.id }) {
                    self.store.rounds[index] = updatedRound
                    self.store.saveRounds()

                    // Sync to Watch
                    WatchConnectivityManager.shared.sendRound(updatedRound)
                }
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
    private var aimArrowRotation: Double {
        guard let capturedHeading = trajectoryHeading,
              let userLocation = locationManager.location,
              let hole = currentHole,
              let holeCoord = hole.coordinate else {
            return 0 // Arrow points up when not set
        }

        // Calculate bearing to hole
        let bearingToHole = MapCalculations.calculateBearing(from: userLocation.coordinate, to: holeCoord)

        // Calculate offset: how much the aim direction differs from hole bearing
        let offset = (capturedHeading - bearingToHole + 360).truncatingRemainder(dividingBy: 360)

        // Convert to -180 to 180 range for cleaner display
        let normalizedOffset = offset > 180 ? offset - 360 : offset

        return normalizedOffset
    }

    // MARK: - View Components
    private var mainContent: some View {
        ZStack {
            if isAddingHole {
                AddHoleMapView(
                    position: $position,
                    temporaryHolePosition: $temporaryHolePosition,
                    hasUserInteracted: $hasUserInteractedWithAddHoleMap,
                    userLocation: locationManager.location,
                    heading: locationManager.heading,
                    useStandardMap: useStandardMap
                )
                AddHoleOverlay(
                    holeCount: currentCourse.holes.count,
                    temporaryHolePosition: $temporaryHolePosition,
                    isAddingHole: $isAddingHole,
                    saveTemporaryHole: saveTemporaryHole
                )
            } else if isMovingHoleManually {
                ManualPlacementMapView(
                    position: $position,
                    temporaryPosition: $temporaryPosition,
                    currentHole: currentHole,
                    userLocation: locationManager.location,
                    heading: locationManager.heading,
                    useStandardMap: useStandardMap,
                    isAddingTeeManually: false
                )
                MoveHoleManuallyOverlay(
                    currentHole: currentHole,
                    temporaryPosition: $temporaryPosition,
                    isMovingHoleManually: $isMovingHoleManually,
                    savedMapRegion: $savedMapRegion,
                    userLocation: locationManager.location,
                    store: store,
                    currentCourse: currentCourse,
                    restoreSavedMapRegion: restoreSavedMapRegion
                )
            } else if isMovingStroke {
                StrokeMovementMapView(
                    position: $position,
                    temporaryPosition: $temporaryPosition,
                    currentHole: currentHole,
                    currentRound: currentRound,
                    strokeToMove: strokeToMove,
                    userLocation: locationManager.location,
                    heading: locationManager.heading,
                    useStandardMap: useStandardMap
                )
                MoveStrokeOverlay(
                    strokeToMove: strokeToMove,
                    activeRound: activeRound,
                    temporaryPosition: $temporaryPosition,
                    isMovingStroke: $isMovingStroke,
                    strokeToMoveBinding: $strokeToMove,
                    savedMapRegion: $savedMapRegion,
                    userLocation: locationManager.location,
                    store: store,
                    restoreSavedMapRegion: restoreSavedMapRegion
                )
            } else if isAddingPenaltyStroke {
                PenaltyStrokeMapView(
                    position: $position,
                    temporaryPosition: $temporaryPosition,
                    currentHole: currentHole,
                    currentRound: currentRound,
                    userLocation: locationManager.location,
                    heading: locationManager.heading,
                    useStandardMap: useStandardMap
                )
                AddPenaltyStrokeOverlay(
                    currentHole: currentHole,
                    activeRound: activeRound,
                    temporaryPosition: $temporaryPosition,
                    isAddingPenaltyStroke: $isAddingPenaltyStroke,
                    userLocation: locationManager.location,
                    recordPenaltyStroke: recordPenaltyStroke,
                    updateMapPosition: updateMapPosition
                )
            } else if let hole = currentHole {
                HoleMapView(
                    hole: hole,
                    currentRound: currentRound,
                    userLocation: locationManager.location,
                    heading: locationManager.heading,
                    useStandardMap: useStandardMap,
                    position: $position,
                    targetCoordinates: targetCoordinatesBinding,
                    isPlacingTarget: $isPlacingTarget,
                    isDeleting: $isDeleting,
                    distanceToTarget: distanceToTarget,
                    onHoleTap: {
                        saveCurrentMapRegion()
                        temporaryPosition = hole.coordinate
                        isMovingHoleManually = true
                    },
                    onStrokeTap: { index in
                        selectedStrokeIndex = index
                        showingStrokeDetails = true
                    }
                )
                HoleOverlayControls(
                    hole: hole,
                    strokeCount: strokeCountForCurrentHole,
                    formattedDistance: locationManager.formattedDistance(to: hole.coordinate),
                    errorMessage: locationManager.errorMessage,
                    currentHoleIndex: currentHoleIndex,
                    totalHoles: currentCourse.holes.count,
                    strokes: strokesForCurrentHole,
                    userLocation: locationManager.location,
                    store: store,
                    onPrevious: previousHole,
                    onNext: nextHole,
                    onAddHole: startAddingNextHole
                )
                FloatingButtonsView(
                    hasLocation: locationManager.location != nil,
                    hasActiveRound: activeRound != nil,
                    isCurrentHoleCompleted: isCurrentHoleCompleted,
                    canUndo: canUndo,
                    aimArrowRotation: aimArrowRotation,
                    isPlacingTarget: isPlacingTarget,
                    onFinishHole: finishCurrentHole,
                    onAddPenaltyStroke: {
                        saveCurrentMapRegion()
                        isAddingPenaltyStroke = true
                    },
                    onRecordStroke: {
                        showingClubSelection = true
                    },
                    onCaptureAimDirection: captureAimDirection,
                    onToggleTargetPlacement: toggleTargetPlacement,
                    onUndo: undoLastAction
                )
            } else {
                Color.clear
                    .onAppear {
                        hasUserInteractedWithAddHoleMap = false
                        isAddingHole = true
                    }
            }
        }
    }

    private var mapStyleButton: some View {
        Button(action: {
            useStandardMap.toggle()
        }) {
            Image(systemName: useStandardMap ? "map.fill" : "photo.fill")
        }
    }

    private var viewToggleButton: some View {
        Button(action: {
            updateMapPosition()
        }) {
            Image(systemName: "flag.2.crossed.fill")
        }
        .disabled(currentHole == nil)
    }

    private var editHolePositionButton: some View {
        Button(action: {
            showingMoveHoleConfirmation = true
        }) {
            Image(systemName: "mappin.circle")
        }
        .disabled(currentHole == nil || locationManager.location == nil)
    }

    private var contentWithModifiers: some View {
        mainContent
            .ignoresSafeArea(edges: .all)
            .navigationTitle(currentCourse.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    viewToggleButton
                    mapStyleButton
                    editHolePositionButton
                }
            }
            .modifier(NavigationModifier(showingCourseEditor: $showingCourseEditor, store: store, currentCourse: currentCourse))
            .modifier(HoleEditingModifier(
                showingMoveHoleConfirmation: $showingMoveHoleConfirmation,
                currentHole: currentHole,
                locationManager: locationManager,
                temporaryPosition: $temporaryPosition,
                isMovingHoleManually: $isMovingHoleManually,
                store: store,
                currentCourse: currentCourse,
                moveCurrentHoleToUserLocation: moveCurrentHoleToUserLocation
            ))
            .confirmationDialog("Select Club", isPresented: $showingClubSelection) {
                let types = store.getTypesWithActiveClubs()
                if types.isEmpty {
                    Button("No clubs available") {}
                        .disabled(true)
                } else {
                    ForEach(types) { clubType in
                        Button(clubType.name) {
                            if let club = store.getActiveClubForType(clubType.id) {
                                recordStroke(with: club)
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Which club did you use for this stroke?")
            }
            .modifier(StrokeDetailsModifier(
                showingStrokeDetails: $showingStrokeDetails,
                activeRound: activeRound,
                strokesForCurrentHole: strokesForCurrentHole,
                selectedStrokeIndex: $selectedStrokeIndex,
                isMovingStroke: $isMovingStroke,
                strokeToMove: $strokeToMove,
                temporaryPosition: $temporaryPosition,
                position: $position,
                savedMapRegion: $savedMapRegion,
                store: store
            ))
    }

    // MARK: - Body
    var body: some View {
        contentWithModifiers
            .onAppear {
                locationManager.requestPermission()

            // Start round automatically or resume existing round
            if activeRound == nil {
                if let resumingRound = resumingRound {
                    activeRound = resumingRound
                } else {
                    activeRound = store.startRound(for: currentCourse)
                }
            }

            // Sync current hole index to watch on initial load
            if let round = activeRound {
                store.updateCurrentHoleIndex(for: round, newIndex: currentHoleIndex)
            }

            // Update map based on mode
            if isAddingHole {
                updateAddHoleMapPosition()
            } else {
                updateMapPosition()
            }
        }
        .onChange(of: currentHoleIndex) { _, _ in
            updateMapPosition()
        }
        .onChange(of: locationManager.location) { _, newLocation in
            // When adding first hole and location becomes available, center the map
            // Only auto-center if user hasn't started interacting with the map
            if isAddingHole && currentCourse.holes.isEmpty && newLocation != nil && !hasUserInteractedWithAddHoleMap {
                updateAddHoleMapPosition()
            }
        }
        .onChange(of: isAddingHole) { _, newValue in
            if newValue {
                hasUserInteractedWithAddHoleMap = false
                updateAddHoleMapPosition()
            } else {
                updateMapPosition()
            }
        }
        .onChange(of: currentCourse.holes.count) { oldCount, newCount in
            // If holes count increased, it came from watch - close add hole screen if open
            if newCount > oldCount {
                print("📱 [HolePlayView] New hole detected from watch (count: \(oldCount) -> \(newCount))")
                if isAddingHole {
                    print("📱 [HolePlayView] Closing add hole screen, navigating to new hole")
                    isAddingHole = false
                    // Update to the new hole index
                    currentHoleIndex = newCount - 1
                }
            }
        }
        .onChange(of: currentHole) { oldHole, newHole in
            // If we're in add hole mode but now have a valid hole, close add hole screen
            // This handles watch navigation or watch creating a hole
            if isAddingHole && newHole != nil {
                print("📱 [HolePlayView] Valid hole now exists, closing add hole screen")
                isAddingHole = false
            }
        }
        // --- Begin new onChange blocks for edit modes ---
        .onChange(of: isMovingHoleManually) { _, newValue in
            if newValue {
                // Entering hole-move mode: show full hole view
                saveCurrentMapRegion()
            } else {
                // Exiting hole-move mode: return to regular user/hole view
                updateMapPosition()
            }
        }
        .onChange(of: isMovingStroke) { _, newValue in
            if newValue {
                // Entering stroke-move mode: show full hole view
                saveCurrentMapRegion()
            } else {
                // Exiting stroke-move mode: return to regular user/hole view
                updateMapPosition()
            }
        }
        .onChange(of: isAddingPenaltyStroke) { _, newValue in
            if newValue {
                // Entering penalty stroke mode: already called saveCurrentMapRegion
            } else {
                // Exiting penalty stroke mode: return to regular user/hole view
                updateMapPosition()
            }
        }
        // --- End new onChange blocks for edit modes ---
        .onChange(of: currentRound?.currentHoleIndex) { _, newIndex in
            if let newIndex = newIndex, newIndex != currentHoleIndex {
                print("📱 [HolePlayView] Syncing hole index from Watch: \(newIndex)")
                currentHoleIndex = newIndex
            }
        }
    }

    // MARK: - Navigation Functions
    private func previousHole() {
        guard let round = activeRound else { return }
        if currentHoleIndex > 0 {
            currentHoleIndex -= 1
            store.updateCurrentHoleIndex(for: round, newIndex: currentHoleIndex)
        }
    }

    private func nextHole() {
        guard let round = activeRound else { return }
        if currentHoleIndex < currentCourse.holes.count - 1 {
            currentHoleIndex += 1
            store.updateCurrentHoleIndex(for: round, newIndex: currentHoleIndex)
        }
    }

    private func finishCurrentHole() {
        guard let round = activeRound,
              let hole = currentHole else { return }

        // Mark hole as completed
        store.completeHole(in: round, holeNumber: hole.number)

        // Auto-advance to next hole if available, or start adding a new hole
        if currentHoleIndex < currentCourse.holes.count - 1 {
            currentHoleIndex += 1
            store.updateCurrentHoleIndex(for: round, newIndex: currentHoleIndex)
        } else {
            // No more holes, start adding a new one
            hasUserInteractedWithAddHoleMap = false
            isAddingHole = true
        }
    }

    private func reopenCurrentHole() {
        guard let round = activeRound,
              let hole = currentHole else { return }

        // Remove hole from completed set
        store.reopenHole(in: round, holeNumber: hole.number)
    }

    // MARK: - Stroke Recording Functions
    private func captureAimDirection() {
        var heading: Double?

        // Try to get real heading first
        if let realHeading = locationManager.heading {
            heading = realHeading
        } else if let userLocation = locationManager.location,
                  let hole = currentHole,
                  let holeCoord = hole.coordinate {
            // Fallback: Use bearing to hole + 45 degrees as simulated offset
            let bearingToHole = MapCalculations.calculateBearing(from: userLocation.coordinate, to: holeCoord)
            heading = (bearingToHole + 45).truncatingRemainder(dividingBy: 360)
        }

        guard let finalHeading = heading else { return }

        // Capture the current heading
        trajectoryHeading = finalHeading
    }

    private func toggleTargetPlacement() {
        isPlacingTarget.toggle()
    }

    private func undoLastAction() {
        guard let round = activeRound else { return }

        // Check if current hole is completed - if so, undo the completion first
        if let currentHole = currentHole, currentRound?.isHoleCompleted(currentHole.number) == true {
            store.reopenHole(in: round, holeNumber: currentHole.number)
            return
        }

        // If there are strokes on current hole, delete the last one
        if let lastStroke = strokesForCurrentHole.last {
            store.deleteStroke(in: round, stroke: lastStroke)
        } else if currentHoleIndex > 0 {
            // No strokes on current hole - check if we just finished the previous hole
            // Only undo if: we're on a hole with no strokes AND the immediately previous hole is completed
            let previousHoleIdx = currentHoleIndex - 1
            let previousHoleNumber = currentCourse.holes[previousHoleIdx].number

            if currentRound?.isHoleCompleted(previousHoleNumber) == true {
                // Undo the hole completion and go back to previous hole
                store.reopenHole(in: round, holeNumber: previousHoleNumber)
                currentHoleIndex = previousHoleIdx
                store.updateCurrentHoleIndex(for: round, newIndex: currentHoleIndex)
            }
        }
    }

    // MARK: - Map Region Functions
    private func saveCurrentMapRegion() {
        guard let hole = currentHole,
              let holeCoord = hole.coordinate else { return }

        // Use user location as the start
        let startCoord: CLLocationCoordinate2D

        if let userCoord = locationManager.location?.coordinate {
            startCoord = userCoord
        } else {
            // Fallback: just show a tight region around the hole.
            position = .region(MKCoordinateRegion(
                center: holeCoord,
                span: MKCoordinateSpan(latitudeDelta: 0.0005, longitudeDelta: 0.0005)
            ))
            return
        }

        // Compute distance between start and hole
        let startLocation = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
        let holeLocation = CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude)
        let distance = max(startLocation.distance(from: holeLocation), 40.0)

        // Center point exactly between start and hole
        let centerLat = (holeCoord.latitude + startCoord.latitude) / 2.0
        let centerLon = (holeCoord.longitude + startCoord.longitude) / 2.0
        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)

        // Bearing from start (tee/user) to hole so hole is at the "top" of the screen
        let bearing = MapCalculations.calculateBearing(from: startCoord, to: holeCoord)

        // Use a similar zoom logic to the regular view: expand based on distance
        let spanInMeters = max(distance * 1.8, 40.0)
        let camera = MapCamera(
            centerCoordinate: center,
            distance: spanInMeters * 2.2,
            heading: bearing,
            pitch: 0
        )

        position = .camera(camera)
    }

    private func restoreSavedMapRegion() {
        updateMapPosition()
    }

    // MARK: - Hole Editing Functions
    private func moveCurrentHoleToUserLocation() {
        guard let hole = currentHole,
              let location = locationManager.location else { return }
        store.updateHole(hole, in: currentCourse, newCoordinate: location.coordinate)
    }

    private func recordStroke(with club: ClubData) {
        guard let round = activeRound,
              let hole = currentHole,
              let location = locationManager.location else { return }

        // Use manual trajectory if set, otherwise calculate bearing to hole (if hole has coordinates)
        var heading: Double = 0
        if let traj = trajectoryHeading {
            heading = traj
        } else if let holeCoord = hole.coordinate {
            heading = MapCalculations.calculateBearing(from: location.coordinate, to: holeCoord)
        }

        store.addStroke(to: round, holeNumber: hole.number, coordinate: location.coordinate, clubId: club.id, trajectoryHeading: heading)

        // Reset aim direction after recording stroke
        trajectoryHeading = nil
    }

    private func recordPenaltyStroke() {
        guard let round = activeRound,
              let hole = currentHole,
              let coordinate = temporaryPosition else { return }

        // Use the club from the most recent stroke, or default to putter if no previous strokes
        let clubId: UUID = {
            if let recentClubId = mostRecentStroke?.clubId {
                return recentClubId
            }
            // Default to putter from active set, or first available type's club
            let types = store.getTypesWithActiveClubs()
            // Try to find a putter type
            if let putterType = types.first(where: { $0.name.lowercased().contains("putter") }),
               let putterClub = store.getActiveClubForType(putterType.id) {
                return putterClub.id
            }
            // Fallback to first type's active club
            if let firstType = types.first,
               let firstClub = store.getActiveClubForType(firstType.id) {
                return firstClub.id
            }
            return UUID() // Fallback to new UUID
        }()

        store.addPenaltyStroke(to: round, holeNumber: hole.number, coordinate: coordinate, clubId: clubId)
        isAddingPenaltyStroke = false
        temporaryPosition = nil
    }

    private func startAddingNextHole() {
        isAddingHole = true
        temporaryHolePosition = nil
        hasUserInteractedWithAddHoleMap = false
        updateAddHoleMapPosition()
    }

    private func saveTemporaryHole(par: Int) {
        guard let coordinate = temporaryHolePosition else { return }

        // Save the hole with par, passing user location for optimal crop centering
        store.addHole(to: currentCourse, coordinate: coordinate, par: par, userLocation: locationManager.location?.coordinate)

        // Navigate to the newly added hole
        currentHoleIndex = currentCourse.holes.count - 1

        // Exit add mode
        isAddingHole = false
        temporaryHolePosition = nil

        // Update map position for the new hole (will be triggered by updateMapPosition)
        updateMapPosition()
    }

    private func updateAddHoleMapPosition() {
        guard let userLocation = locationManager.location else { return }

        // Show area ~350 yards (320 meters) around the user
        let spanInMeters: CLLocationDistance = 320.0
        let spanDegrees = spanInMeters / 111000.0 // rough conversion

        position = .region(MKCoordinateRegion(
            center: userLocation.coordinate,
            span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
        ))
    }

    private func updateMapPosition() {
        guard let hole = currentHole,
              let holeCoord = hole.coordinate else { return }

        if let userLocation = locationManager.location {
            let userCoord = userLocation.coordinate
            let holeLocation = CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude)

            // ALWAYS show user-to-hole view (user at bottom, hole at top)
            let startCoord = userCoord

            // Calculate bearing and distance from user to hole
            let bearing = MapCalculations.calculateBearing(from: startCoord, to: holeCoord)
            let startLocation = CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
            let distance = max(startLocation.distance(from: holeLocation), 40.0)

            // Calculate span based on distance
            let spanInMeters = max(distance * 1.8, 40.0) // Minimum 40 meters view

            // Center point exactly between user and hole
            let centerLat = (holeCoord.latitude + startCoord.latitude) / 2.0
            let centerLon = (holeCoord.longitude + startCoord.longitude) / 2.0
            let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)

            // Create camera with rotation so hole is always at top
            // Increased distance to zoom out more, giving space above hole for yardage display
            let camera = MapCamera(
                centerCoordinate: center,
                distance: spanInMeters * 2.2, // Zoom out more for extra space at top
                heading: bearing, // Rotate map so bearing points up
                pitch: 0
            )

            position = .camera(camera)
        } else {
            // No user location - just center on the hole
            position = .region(MKCoordinateRegion(
                center: holeCoord,
                span: MKCoordinateSpan(latitudeDelta: 0.0005, longitudeDelta: 0.0005)
            ))
        }
    }
}
