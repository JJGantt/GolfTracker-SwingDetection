import SwiftUI
import MapKit

struct HolePlayView: View {
    @ObservedObject var store: DataStore
    let course: Course
    let resumingRound: Round?
    let runHoleDetectionAtStart: Bool
    let runHoleDetectionWithTestCoordinates: Bool

    @Environment(\.dismiss) private var dismiss

    // MARK: - Core State
    @StateObject var locationManager = LocationManager()
    /// Set only when the screen was opened on a hole to look at it (a round's
    /// detail), and moved by Previous/Next there. Nil in play, where the hole
    /// on screen is the round's `currentHoleNumber` (the value both devices
    /// read), so this screen keeps no hole of its own.
    @State var reviewHoleNumber: Int?
    @State var activeRound: Round?

    // MARK: - Map State
    @State var position = MapCameraPosition.automatic
    @State var useStandardMap = false
    @State var savedMapRegion: MKCoordinateRegion?

    // MARK: - Editing Modes
    @State var isAddingHole = false
    @State var isMovingHoleManually = false
    @State var isMovingStroke = false
    @State var isAddingPenaltyStroke = false
    @State var hasUserInteractedWithAddHoleMap = false
    @State var isAddHoleManualMode = false
    @State var addHoleSelectedBlobId: UUID?

    // MARK: - Temporary Positions
    @State var temporaryHolePosition: CLLocationCoordinate2D?
    @State var temporaryPosition: CLLocationCoordinate2D?
    @State var strokeToMove: Stroke?

    // MARK: - Dialogs & Sheets
    @State var showingMoveHoleConfirmation = false
    @State var showingClubSelection = false
    @State var showingStrokeDetails = false
    @State var showingCourseEditor = false
    @State var showingRoundSummary = false

    // MARK: - Input State
    @State var selectedStrokeIndex: Int = 0

    // MARK: - Stroke Recording
    @State var trajectoryHeading: Double? = nil

    // MARK: - Target Placement
    @State var isPlacingTarget = false
    @State var isDeleting = false

    // MARK: - Initialization
    init(
        store: DataStore,
        course: Course,
        resumingRound: Round? = nil,
        startingHoleNumber: Int? = nil,
        runHoleDetectionAtStart: Bool = true,
        runHoleDetectionWithTestCoordinates: Bool = false
    ) {
        self.store = store
        self.course = course
        self.resumingRound = resumingRound
        self.runHoleDetectionAtStart = runHoleDetectionAtStart
        self.runHoleDetectionWithTestCoordinates = runHoleDetectionWithTestCoordinates
        _reviewHoleNumber = State(initialValue: startingHoleNumber)
    }

    // MARK: - Computed Properties
    var currentCourse: Course {
        store.courses.first { $0.id == course.id } ?? course
    }

    /// The round's own holes in number order, as the watch reads them; the
    /// course's only before a round exists.
    var holesSorted: [Hole] {
        (activeRound?.holes ?? currentCourse.holes).sorted { $0.number < $1.number }
    }

    /// The hole on screen, by number: in play, the round's current hole.
    var currentHoleNumber: Int {
        reviewHoleNumber ?? (currentRound ?? activeRound)?.currentHoleNumber ?? 1
    }

    var currentHole: Hole? {
        holesSorted.first { $0.number == currentHoleNumber }
    }

    var currentRound: Round? {
        guard let activeRound = activeRound else { return nil }
        return store.rounds.first { $0.id == activeRound.id }
    }

    var strokeCountForCurrentHole: Int {
        guard let round = currentRound,
              let hole = currentHole else { return 0 }
        return round.strokes.filter { $0.holeNumber == hole.number }.count
    }

    var strokesForCurrentHole: [Stroke] {
        guard let round = currentRound,
              let hole = currentHole else { return [] }
        return round.strokes
            .filter { $0.holeNumber == hole.number }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var mostRecentStroke: Stroke? {
        return strokesForCurrentHole.last
    }

    var effectiveTrajectoryHeading: Double? {
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

    var selectedStroke: Stroke? {
        guard selectedStrokeIndex < strokesForCurrentHole.count else { return nil }
        return strokesForCurrentHole[selectedStrokeIndex]
    }

    var isCurrentHoleCompleted: Bool {
        guard let round = currentRound,
              let hole = currentHole else { return false }
        return round.isHoleCompleted(hole.number)
    }

    var canUndo: Bool {
        guard activeRound != nil else { return false }

        // Can undo if there are strokes on current hole
        if !strokesForCurrentHole.isEmpty {
            return true
        }

        // Can undo if we just finished the previous hole (no strokes on current, previous is completed)
        if let round = currentRound, let previous = round.hole(before: currentHoleNumber) {
            return round.isHoleCompleted(previous.number)
        }

        return false
    }

    var targetCoordinatesBinding: Binding<[CLLocationCoordinate2D]> {
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
                self.store.setTargets(for: round, holeNumber: hole.number, coordinates: newCoordinates)
            }
        )
    }

    func distanceToTarget(_ target: CLLocationCoordinate2D) -> Int? {
        guard let userLocation = locationManager.location else { return nil }

        let targetLocation = CLLocation(
            latitude: target.latitude,
            longitude: target.longitude
        )

        let distanceInMeters = userLocation.distance(from: targetLocation)
        return Int(distanceInMeters * 1.09361) // Convert to yards
    }

    // Calculate the rotation angle for the aim arrow
    var aimArrowRotation: Double {
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
    var mainContent: some View {
        ZStack {
            if isAddingHole {
                addHoleModeContent()
            } else if isMovingHoleManually {
                moveHoleModeContent()
            } else if isMovingStroke {
                moveStrokeModeContent()
            } else if isAddingPenaltyStroke {
                addPenaltyModeContent()
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
                    hasPreviousHole: currentRound?.hole(before: currentHoleNumber) != nil,
                    hasNextHole: currentRound?.hole(after: currentHoleNumber) != nil,
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
                    onUndo: undoLastAction,
                    onShowScorecard: { showingRoundSummary = true }
                )
            } else {
                Color.clear
                    .onAppear {
                        hasUserInteractedWithAddHoleMap = false
                        isAddingHole = true
                    }
            }

            if currentRound?.holeDetectionEnabled == true,
               let detectionState = store.holeDetectionStatus(for: currentCourse.id),
               detectionState.isRunning {
                VStack {
                    HStack(spacing: 10) {
                        ProgressView(value: detectionState.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                        Text(detectionState.message)
                            .font(.caption)
                            .foregroundColor(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 90)
                    Spacer()
                }
            }
        }
    }

    var mapStyleButton: some View {
        Button(action: {
            useStandardMap.toggle()
        }) {
            Image(systemName: useStandardMap ? "map.fill" : "photo.fill")
        }
    }

    var viewToggleButton: some View {
        Button(action: {
            updateMapPosition()
        }) {
            Image(systemName: "flag.2.crossed.fill")
        }
        .disabled(currentHole == nil)
    }

    var editHolePositionButton: some View {
        Button(action: {
            showingMoveHoleConfirmation = true
        }) {
            Image(systemName: "mappin.circle")
        }
        .disabled(currentHole == nil || locationManager.location == nil)
    }

    var contentWithModifiers: some View {
        // Measured outside the edge-to-edge content, which can no longer see
        // the safe area once it ignores it — see `playControlsBottomInset`.
        GeometryReader { geo in
            mainContent
                .environment(\.playControlsBottomInset, geo.safeAreaInsets.bottom)
                .ignoresSafeArea(edges: .all)
        }
            .navigationTitle(isAddingHole ? "" : currentCourse.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar(isAddingHole ? .hidden : .automatic, for: .navigationBar)
            .onChange(of: isAddingHole) { _, newValue in
                if !newValue && currentCourse.holes.isEmpty, let r = activeRound {
                    store.deleteRound(r)
                }
            }
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
            .sheet(isPresented: $showingRoundSummary) {
                if let round = currentRound {
                    ScorecardSheet(round: round)
                        .presentationDetents([.medium, .large])
                        .safeAreaInset(edge: .bottom) {
                            EndRoundButton(round: round, store: store, onEnded: {
                                showingRoundSummary = false
                                dismiss()
                            })
                        }
                }
            }
    }

    // MARK: - Body
    var body: some View {
        contentWithModifiers
            .onAppear {
                locationManager.requestPermission()

            // Realtime is round-scoped — start while the play view is visible.
            if let uid = AuthManager.shared.currentUserId {
                RealtimeSync.shared.start(forUserId: uid)
                startPlaygroupChannelIfNeeded(userId: uid)
            }

            // Start round automatically or resume existing round
            if activeRound == nil {
                if let resumingRound = resumingRound {
                    activeRound = resumingRound
                } else {
                    activeRound = store.startRound(
                        for: currentCourse,
                        runHoleDetection: runHoleDetectionAtStart,
                        useHoleDetectionTestCoordinates: runHoleDetectionWithTestCoordinates
                    )
                }
            }

            // Expose the active round id so MultiplayerView can host it.
            store.currentRoundId = activeRound?.id

            applyLocationModeForRound()

            // The hole on screen is read from the round; opening this screen
            // writes nothing.

            // Update map based on mode
            if isAddingHole {
                updateAddHoleMapPosition()
            } else {
                updateMapPosition()
            }

            pushElevationReadoutHole()
            refreshBreadcrumb()
        }
        .onDisappear {
            // Realtime is round-scoped — drop the WebSocket when leaving play.
            RealtimeSync.shared.stop()
            PlaygroupChannel.shared.stop()
            store.currentRoundId = nil
        }
        .onChange(of: currentHoleNumber) { _, newNumber in
            updateMapPosition()
            if let uid = AuthManager.shared.currentUserId {
                PlaygroupChannel.shared.updateCurrentHole(newNumber, userId: uid)
            }
            pushElevationReadoutHole()
            refreshBreadcrumb()
        }
        .onChange(of: currentRound) { _, _ in
            applyLocationModeForRound()
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
                isAddHoleManualMode = false
                addHoleSelectedBlobId = nil
                updateAddHoleMapPosition()
            } else {
                isAddHoleManualMode = false
                addHoleSelectedBlobId = nil
                updateMapPosition()
            }
        }
        .onChange(of: currentRound?.holes.count ?? 0) { oldCount, newCount in
            // A hole added on the watch lands in the round, which already
            // points at it; close the add-hole screen if it's open.
            if newCount > oldCount, isAddingHole {
                isAddingHole = false
            }
        }
        .onChange(of: currentHole) { oldHole, newHole in
            // If we're in add hole mode but now have a valid hole, close add hole screen
            // This handles watch navigation or watch creating a hole
            if isAddingHole && newHole != nil {
                dprint("📱 [HolePlayView] Valid hole now exists, closing add hole screen")
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
    }

    // MARK: - Navigation Functions
    func previousHole() {
        guard let previous = currentRound?.hole(before: currentHoleNumber) else { return }
        goToHole(previous.number)
    }

    func nextHole() {
        guard let next = currentRound?.hole(after: currentHoleNumber) else { return }
        goToHole(next.number)
    }

    /// In play this moves the round, on every device; reviewing a hole moves
    /// only this screen.
    func goToHole(_ number: Int) {
        if reviewHoleNumber != nil {
            reviewHoleNumber = number
        } else if let round = currentRound ?? activeRound {
            store.setCurrentHole(for: round, number: number)
        }
    }

    func finishCurrentHole() {
        guard let round = activeRound,
              let hole = currentHole else { return }

        // Mark hole as completed
        store.completeHole(in: round, holeNumber: hole.number)

        // Auto-advance to next hole if available, or start adding a new hole
        if let next = round.hole(after: hole.number) {
            goToHole(next.number)
        } else {
            // No more holes, start adding a new one
            hasUserInteractedWithAddHoleMap = false
            isAddingHole = true
        }
    }

    func reopenCurrentHole() {
        guard let round = activeRound,
              let hole = currentHole else { return }

        // Remove hole from completed set
        store.reopenHole(in: round, holeNumber: hole.number)
    }

    // MARK: - Stroke Recording Functions
    func captureAimDirection() {
        // Compass only. The old fallback synthesised "bearing to hole + 45°"
        // when no heading was available — test scaffolding that wrote a
        // fabricated aim into a real stroke record. With no compass fix there
        // is no aim to capture, so leave it unset.
        guard let realHeading = locationManager.heading else { return }
        trajectoryHeading = realHeading
    }

    func toggleTargetPlacement() {
        isPlacingTarget.toggle()
    }

    func undoLastAction() {
        guard let round = activeRound else { return }

        // Check if current hole is completed - if so, undo the completion first
        if let currentHole = currentHole, currentRound?.isHoleCompleted(currentHole.number) == true {
            store.reopenHole(in: round, holeNumber: currentHole.number)
            return
        }

        // If there are strokes on current hole, delete the last one
        if let lastStroke = strokesForCurrentHole.last {
            store.deleteStroke(in: round, stroke: lastStroke)
        } else if let previous = currentRound?.hole(before: currentHoleNumber),
                  currentRound?.isHoleCompleted(previous.number) == true {
            // No strokes here and the previous hole was just finished: reopen
            // it and go back to it.
            store.reopenHole(in: round, holeNumber: previous.number)
            goToHole(previous.number)
        }
    }

    // MARK: - Map Region Functions
    func saveCurrentMapRegion() {
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

    func restoreSavedMapRegion() {
        updateMapPosition()
    }

    // MARK: - Hole Editing Functions
    func moveCurrentHoleToUserLocation() {
        guard let hole = currentHole,
              let location = locationManager.location else { return }
        store.updateHole(hole, in: currentCourse, newCoordinate: location.coordinate)
    }

    func recordStroke(with club: ClubData) {
        guard let round = activeRound,
              let hole = currentHole,
              let location = locationManager.location else { return }

        // Only a real captured aim goes on the stroke. This used to fall back
        // to bearing-to-hole (and, failing that, a literal 0°), which made
        // Stroke.trajectoryHeading indistinguishable from a measurement while
        // carrying none. Nil means unknown.
        store.addStroke(to: round, holeNumber: hole.number, coordinate: location.coordinate, clubId: club.id, trajectoryHeading: trajectoryHeading)

        // Reset aim direction after recording stroke
        trajectoryHeading = nil
    }

    func recordPenaltyStroke() {
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
            if let putterType = types.first(where: { $0.name == "Putt" }),
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

    func startAddingNextHole() {
        isAddingHole = true
        temporaryHolePosition = nil
        hasUserInteractedWithAddHoleMap = false
        updateAddHoleMapPosition()
    }

    func saveTemporaryHole(par: Int) {
        guard let coordinate = temporaryHolePosition else { return }

        // Save the hole with par, passing user location for optimal crop centering
        store.addHole(to: currentCourse, coordinate: coordinate, par: par, userLocation: locationManager.location?.coordinate)

        // addHole points the round at the new hole.

        // Exit add mode
        isAddingHole = false
        temporaryHolePosition = nil

        // Update map position for the new hole (will be triggered by updateMapPosition)
        updateMapPosition()
    }

    func updateAddHoleMapPosition() {
        guard let userLocation = locationManager.location else { return }

        // Show area ~350 yards (320 meters) around the user
        let spanInMeters: CLLocationDistance = 320.0
        let spanDegrees = spanInMeters / 111000.0 // rough conversion

        position = .region(MKCoordinateRegion(
            center: userLocation.coordinate,
            span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees)
        ))
    }

    func applyLocationModeForRound() {
        // No-op now. Used to read `round.locationTestModeEnabled` (a legacy
        // per-round flag) and force LocationManager into/out of test mode.
        // That fought with the global TestModeService (writes user_test_state,
        // syncs cross-device via Realtime). Test mode is now exclusively
        // owned by TestModeService — round lifecycle doesn't toggle it.
    }

    /// Aims the map from the hole's tee to the pin: the watch's default
    /// framing (`ActiveRoundView.updateMapPosition`). It stays put for the
    /// hole rather than following the user, so the shots already hit, their
    /// distances and the trail stay on screen; framing from the user put all
    /// of them below the bottom edge.
    func updateMapPosition() {
        guard let hole = currentHole,
              let holeCoord = hole.coordinate else { return }

        guard let startCoord = teeCoordinate(for: hole)
                ?? strokesForCurrentHole.min(by: { $0.strokeNumber < $1.strokeNumber })?.coordinate
                ?? locationManager.location?.coordinate else {
            position = .region(MKCoordinateRegion(
                center: holeCoord,
                span: MKCoordinateSpan(latitudeDelta: 0.0005, longitudeDelta: 0.0005)
            ))
            return
        }

        let bearing = MapCalculations.calculateBearing(from: startCoord, to: holeCoord)
        let distance = max(
            CLLocation(latitude: startCoord.latitude, longitude: startCoord.longitude)
                .distance(from: CLLocation(latitude: holeCoord.latitude, longitude: holeCoord.longitude)),
            40.0
        )
        let center = CLLocationCoordinate2D(
            latitude: (holeCoord.latitude + startCoord.latitude) / 2.0,
            longitude: (holeCoord.longitude + startCoord.longitude) / 2.0
        )
        // 4.4x the tee-to-pin distance keeps the tee's shot marker and its
        // yardage clear of the hole panel at the bottom, and the pin clear of
        // the yardage header at the top.
        position = .camera(MapCamera(centerCoordinate: center, distance: distance * 4.4, heading: bearing, pitch: 0))
    }

    /// The tee end of the course map's centerline for this hole, as the watch
    /// uses it. Full-tier coverage only: partial-tier refs can be mismapped.
    private func teeCoordinate(for hole: Hole) -> CLLocationCoordinate2D? {
        guard let osm = store.osmCourseData(forCourseId: currentCourse.id), osm.tier == .full else { return nil }
        return osm.holes.first { Int($0.ref ?? "") == hole.number }?.centerline.first?.coordinate
    }

    /// Spin up the playgroup Realtime channel if the user is in an open
    /// playgroup. Async because we need to look up `currentOpenPlaygroup`
    /// before deciding; no-ops when not in one.
    private func startPlaygroupChannelIfNeeded(userId: String) {
        let holeNumber = currentHoleNumber
        let roundId = activeRound?.id
        Task {
            do {
                guard let pg = try await PlaygroupService.shared.currentOpenPlaygroup() else { return }
                await MainActor.run {
                    // `roundId` points my membership row at this round — a
                    // joiner's row starts with round_id nil, and without it
                    // the shared scorecard can't see me.
                    PlaygroupChannel.shared.start(playgroupId: pg.id, currentHole: holeNumber,
                                                  userId: userId, roundId: roundId)
                }
            } catch {
                print("📡 [HolePlayView] PlaygroupChannel start check failed: \(error.localizedDescription)")
            }
        }
    }

    /// Forward the current hole + green coord into ElevationReadout so
    /// the live Δ-to-green tracks the player's hole. The "green" passed
    /// is `Hole.coordinate` (green centroid for OSM rounds, user-placed
    /// pin for manual rounds).
    func pushElevationReadoutHole() {
        guard let hole = currentHole else { return }
        ElevationReadout.shared.updateHole(number: hole.number, green: hole.coordinate)
    }

    /// Pull breadcrumb data for the active round + current hole from
    /// `round_altitude_readings`. Up-to-30s stale (matches the watch's
    /// upload flush cadence). Force-refreshes on each call so a hole
    /// that's currently being played picks up new samples on every
    /// hole-index change. Cached per (roundId, holeNumber) so back-nav
    /// between holes during a session doesn't refetch unnecessarily.
    func refreshBreadcrumb() {
        guard let round = activeRound, let hole = currentHole else { return }
        // Force refresh in play (the hole is live and may have new uploads),
        // cache-first when reviewing a hole (its data is settled).
        let isCurrentHole = reviewHoleNumber == nil
        RoundPathCache.shared.loadIfNeeded(
            roundId: round.id,
            holeNumber: hole.number,
            forceRefresh: isCurrentHole
        )
        // Ghost overlay rides the same refresh points (appear, hole
        // change, toggle flip). No-ops when the overlay is off.
        GhostRoundStore.shared.loadIfNeeded(
            courseId: round.courseId,
            excludingRoundId: round.id,
            holeNumber: hole.number
        )
    }
}
