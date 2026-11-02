import SwiftUI
import MapKit
import WatchKit

struct ActiveRoundView: View {
    @StateObject var store = WatchDataStore.shared
    @ObservedObject var locationManager = LocationManager.shared
    @StateObject var swingDetector = SwingDetectionManager.shared
    @StateObject var workoutManager = WorkoutManager.shared
    @ObservedObject var playgroupChannel = PlaygroupChannel.shared
    @ObservedObject var ghost = GhostRoundStore.shared
    /// Big yardage readout mode: false = measured distance, true =
    /// plays-like (elevation-adjusted for the selected club). Toggled by
    /// tapping the number; persists across holes and rounds.
    @AppStorage("yardageShowsPlaysLike") var yardageShowsPlaysLike = false
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.dismiss) var dismiss
    @AppStorage("minimalScreenMode") var minimalScreenMode: Bool = false
    @State var selectedClubIndex: Double = 0
    @State var position: MapCameraPosition = .automatic
    @State var showingRecordedFeedback = false
    @State var crownOffset: CGFloat = 0
    @State var isPlacingTarget = false
    @State var showingUndoConfirmation = false
    @State var showingOptions = false
    @State var showingEditHole = false
    @State var isLastStrokeViewMode = false
    // Defaults to full hole view (tee → green) — matches the multiplayer use
    // case (you want to see all players' positions across the hole) and also
    // helps solo players see the whole hole layout up front.
    @State var isFullViewMode = true
    @State var isCrownScrolling = false
    @State var crownScrollTimer: Timer?
    /// Tracks the last *integer* club index we propagated to the swing
    /// detector. The crown binding is `Double` and ticks 30-60×/s; the
    /// rounded integer (the actual selected club) only changes once per
    /// click. We only do the heavy work on integer changes.
    @State var lastSettledClubIndex: Int = -1
    /// Tracks the last-seen value of `isOnCurrentGreen` so the diagnostic
    /// log fires only on transitions, not on every location update.
    @State var lastLoggedOnGreen: Bool = false
    /// Last time the green-state log fired. Throttles the periodic log
    /// to once per 5 seconds so we get snapshots even when nowOnGreen
    /// is stuck at false (e.g. user far from any polygon).
    @State var lastLoggedGreenAt: Date? = nil
    @State var isPulsing = false
    @State var showingDistanceEditor = false
    @State var showingScorecard = false
    @State var manualClubOverride = false       // True when user manually changed club
    @State var onGreenOverride = false          // True when auto-switched to putter for current green
    @State var navigateToViewSettings = false
    @State var navigateToClubRecommend = false

    enum SettingsSheet: String, Identifiable {
        case viewSettings, clubRecommend
        var id: String { rawValue }
    }
    @State var activeSettingsSheet: SettingsSheet?
    @State var isAutoSelectingClub = false      // True when we're programmatically updating club
    /// Stack of auto-added strokes paired with their swing_event row ids.
    /// Each auto-detect → push (strokeId, eventId). Undo button on the main
    /// screen pops from the top: deletes the stroke and edits the swing_event
    /// row to false_positive/high. Manual strokes are NOT in this stack
    /// (they're undoable via the same button but skip event labeling).
    @State var autoAddStack: [(strokeId: UUID, eventId: UUID)] = []
    @State var lastAutoAddedLocation: CLLocationCoordinate2D?  // GPS of last auto-added stroke for practice replacement
    @FocusState var isMapFocused: Bool
    @FocusState var isMainViewFocused: Bool

    /// Clubs the digital crown scrolls through. Uses the user's currently
    /// active ClubSet (e.g., "Default Set", or whichever set they've made
    /// active in the iPhone Club Management view). NOT the full catalog —
    /// alternate clubs that aren't in the active set don't appear in the
    /// round-time crown.
    var clubs: [ClubData] {
        return store.activeSetClubs
    }

    var selectedClub: ClubData? {
        guard !clubs.isEmpty else { return nil }
        let index = Int(selectedClubIndex.rounded()) % clubs.count
        return clubs[index]
    }

    var isInteractiveMapMode: Bool {
        isPlacingTarget
    }

    var currentHoleGreenBlob: HoleDetectionBlob? {
        guard let courseId = store.currentRound?.courseId,
              let holeCoord = store.currentHole?.coordinate else { return nil }
        return store.filteredGreenCandidates(for: courseId)
            .first { $0.contains(holeCoord) }
    }

    var isOnCurrentGreen: Bool {
        guard let userCoord = locationManager.location?.coordinate,
              let blob = currentHoleGreenBlob else { return false }
        if blob.contains(userCoord) { return true }
        // Tolerance ring around the polygon perimeter — treated as
        // "on green" so the auto-putter switch fires while you're walking
        // up to the apron, not only after you cross the edge. Tunable via
        // dev settings (`greenPutterMarginYards`, default 2yd). Set to 0
        // to disable the ring entirely. Uses distance to the nearest
        // polygon EDGE (not the nearest vertex) — a vertex can be much
        // further than the perpendicular foot on a straight edge.
        let marginYd = UserDefaults.standard.object(forKey: "greenPutterMarginYards").flatMap { ($0 as? NSNumber)?.doubleValue }
            ?? 2.0
        guard marginYd > 0 else { return false }
        let pts = blob.polygon
        guard pts.count >= 2 else { return false }
        let metersPerDegLat = 111_000.0
        let cosLat = cos(userCoord.latitude * .pi / 180.0)
        let metersPerDegLon = metersPerDegLat * cosLat
        var minMeters = Double.greatestFiniteMagnitude
        for i in 0..<pts.count {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            let ax = (a.longitude - userCoord.longitude) * metersPerDegLon
            let ay = (a.latitude - userCoord.latitude) * metersPerDegLat
            let bx = (b.longitude - userCoord.longitude) * metersPerDegLon
            let by = (b.latitude - userCoord.latitude) * metersPerDegLat
            let dx = bx - ax
            let dy = by - ay
            let lenSq = dx * dx + dy * dy
            let dist: Double
            if lenSq > 0 {
                let t = max(0.0, min(1.0, -(ax * dx + ay * dy) / lenSq))
                let cx = ax + t * dx
                let cy = ay + t * dy
                dist = sqrt(cx * cx + cy * cy)
            } else {
                dist = sqrt(ax * ax + ay * ay)
            }
            if dist < minMeters { minMeters = dist }
        }
        return (minMeters * 1.09361) <= marginYd
    }

    var targetCoordinatesBinding: Binding<[CLLocationCoordinate2D]> {
        Binding(
            get: {
                guard let round = self.store.currentRound,
                      let hole = self.store.currentHole else { return [] }
                return round.targets
                    .filter { $0.holeNumber == hole.number }
                    .map { $0.coordinate }
            },
            set: { newCoordinates in
                self.store.replaceTargets(forHoleNumber: self.store.currentHole?.number, with: newCoordinates)
            }
        )
    }

    @ViewBuilder
    func mainContent(geometry: GeometryProxy) -> some View {
        let buttonSize = geometry.size.width * 0.25
        let iconSize = buttonSize * 0.45
        let clubFontSize = geometry.size.width * 0.055
        let needsInteractiveMap = isInteractiveMapMode

        ZStack {
            // Full screen map or black background
            if minimalScreenMode && !needsInteractiveMap {
                Color.black.ignoresSafeArea()
            } else if let hole = store.currentHole, hole.hasLocation {
                // Only render the standard map when the current hole has a
                // placed flag. A newly-added hole (just clicked "+" in
                // OptionsView) has no coordinate; rendering through
                // mapView() force-unwraps `hole.coordinate` and crashes.
                // The rootBodyContent guard SHOULD switch to
                // HolePlacementView when needsFlagPlacement flips, but
                // SwiftUI evaluates mainContent in the same render pass,
                // so we add a belt-and-suspenders check here.
                mapView(for: hole)
                    .ignoresSafeArea()
            } else {
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

            // Invisible button for double-tap gesture (clench fingers twice)
            // Uses detected swing if available, otherwise adds regular stroke
            Button(action: handleDoubleTapGesture) {
                Color.clear
                    .frame(width: 1, height: 1)
            }
            .buttonStyle(PlainButtonStyle())
            .modifier(HandGestureShortcutModifier())
            .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false || isPlacingTarget)
        }
        .task {
            calculateCrownOffset(screenHeight: geometry.size.height)
        }
    }

    func isPuttStroke(_ stroke: Stroke) -> Bool {
        guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return false }
        return store.getTypeName(for: club) == "Putt"
    }

    /// Whether the current hole needs its flag location to be set
    var needsFlagPlacement: Bool {
        guard let hole = store.currentHole else { return false }
        return !hole.hasLocation
    }

    /// Kick the ghost-round store for the current hole. Safe to call
    /// repeatedly; the store no-ops when disabled or already cached.
    func loadGhostForCurrentHole() {
        guard let round = store.currentRound, let hole = store.currentHole else { return }
        ghost.loadIfNeeded(courseId: round.courseId, excludingRoundId: round.id, holeNumber: hole.number)
    }

    var activeRoundContent: some View {
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

    var rootBodyContent: some View {
        Group {
            if needsFlagPlacement, let hole = store.currentHole {
                HolePlacementView(store: store, locationManager: locationManager, hole: hole, isEditing: false)
            } else {
                activeRoundContent
            }
        }
        // Log only when the conditional flips — much quieter than a per-eval
        // log and avoids spawning a Task on every render.
        .onChange(of: needsFlagPlacement) { _, newValue in
            ClientEventLogger.log("needsFlagPlacement.changed", detail: [
                "value": .bool(newValue),
                "currentHoleNumber": store.currentRound.map { .integer($0.currentHoleNumber) } ?? .null,
                "holesCount": store.currentRound.map { .integer($0.holes.count) } ?? .null
            ])
        }
        // Ghost-round overlay data — lazy per-hole fetch, re-checked on
        // appear and hole change (toggle-on mid-hole is handled inside
        // the store via its remembered last request). No-ops when
        // disabled or already cached.
        .onAppear { loadGhostForCurrentHole() }
        .onChange(of: store.currentRound?.currentHoleNumber) { _, _ in loadGhostForCurrentHole() }
    }

    var body: some View {
        WatchDiagnostics.shared.recordBodyEval()
        return ActiveRoundConfiguredView(
            content: AnyView(rootBodyContent),
            store: store,
            locationManager: locationManager,
            showingOptions: $showingOptions,
            showingEditHole: $showingEditHole,
            showingDistanceEditor: $showingDistanceEditor,
            activeSettingsSheet: $activeSettingsSheet,
            isFullViewMode: $isFullViewMode,
            manualClubOverride: $manualClubOverride,
            navigateToViewSettings: $navigateToViewSettings,
            navigateToClubRecommend: $navigateToClubRecommend,
            isPlacingTarget: $isPlacingTarget,
            minimalScreenMode: $minimalScreenMode,
            selectedClubIndex: $selectedClubIndex,
            currentHole: store.currentHole,
            distanceToHole: distanceToHole,
            detectedSwingTimestamp: swingDetector.lastDetectedSwing?.timestamp,
            dismissParent: { dismiss() },
            updateMapPosition: { updateMapPosition() },
            updateNoHoleMapPosition: updateNoHoleMapPosition,
            onViewAppear: handleViewAppear,
            onViewDisappear: handleViewDisappear,
            onLocationChange: handleLocationChange,
            onDistanceToHoleChange: handleDistanceToHoleChange,
            onCurrentHoleNumberChange: handleCurrentHoleNumberChange,
            onCurrentHoleChange: handleCurrentHoleChange,
            onShowingOptionsChange: handleShowingOptionsChange,
            onMinimalScreenModeChange: handleMinimalScreenModeChange,
            onDetectedSwingChange: handleDetectedSwingChange,
            onSelectedClubIndexChange: handleSelectedClubIndexChange
        )
        // Without OSM hole data, full view anchors to the first stroke that still exists, so
        // re-anchor when it is deleted or moved (or the last one goes, falling back to the user's
        // position) rather than waiting for the next GPS fix.
        .onChange(of: [firstStroke?.latitude, firstStroke?.longitude]) { _, _ in
            restoreCalculatedMapPosition()
        }
        .sheet(isPresented: $showingScorecard) {
            if let round = store.currentRound {
                ScorecardSheet(round: round)
            }
        }
        .confirmationDialog(
            "Undo Last Stroke?",
            isPresented: $showingUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button("Undo", role: .destructive) { undoLastStroke() }
            Button("Cancel", role: .cancel) { }
        }
    }

    func handleViewAppear() {
        dprint("⌚ [ActiveRoundView] View appeared")
        locationManager.requestPermission()
        locationManager.startTracking()
        restoreCalculatedMapPosition(force: true)
        isMainViewFocused = true
        swingDetector.startMonitoring()
        updateSwingDetectorClub()

        // Realtime on the watch is gated to multiplayer rounds only. For
        // solo play there's nothing on the network we'd subscribe to —
        // SupabaseSync handles outbound writes via PostgREST through the
        // phone tether at HTTPS speed. Non-LTE watches can't open
        // WebSockets at all, so for the common case the retry loop would
        // just burn battery cycling through "attempt → fail → backoff."
        // RealtimeSync.start gets called inside startPlaygroupChannelIfNeeded
        // ONLY when an active playgroup is found.
        if let uid = WatchAuthSession.shared.currentUserId {
            startPlaygroupChannelIfNeeded(userId: uid)
        }

        pushElevationReadoutHole()

        // Pull any iPhone-side mutations to this round we missed while we
        // weren't subscribed to Realtime (which is the entire solo case).
        // HTTP-only — no WebSocket — so the watchOS-WS unreliability that
        // gates RealtimeSync doesn't apply here. Existing local state
        // renders immediately; updated rows slot in when the fetch returns.
        Task { await RealtimeSync.shared.reconcileRoundsWithSupabase() }

        guard store.currentRound != nil, !workoutManager.isWorkoutActive else { return }
        workoutManager.requestAuthorization { success, _ in
            if success {
                workoutManager.startWorkout()
            }
        }
    }

    func handleViewDisappear() {
        crownScrollTimer?.invalidate()
        RealtimeSync.shared.stop()
        PlaygroupChannel.shared.stop()
    }

    func handleCurrentHoleNumberChange() {
        manualClubOverride = false
        onGreenOverride = false
        lastAutoAddedLocation = nil
        autoAddStack.removeAll()
        locationManager.setGPSPowerMode(.full)
        restoreCalculatedMapPosition(force: true)
        if let uid = WatchAuthSession.shared.currentUserId,
           let round = store.currentRound {
            PlaygroupChannel.shared.updateCurrentHole(round.currentHoleNumber, userId: uid)
        }
        pushElevationReadoutHole()
    }

    /// Forward the current hole + green coord into ElevationReadout so
    /// the live Δ-to-green tracks the player's hole. Called on appear
    /// and on every hole change. The "green" we pass is `Hole.coordinate`
    /// (the hole marker — green centroid for OSM rounds, user-placed
    /// pin for manual rounds).
    func pushElevationReadoutHole() {
        guard let hole = store.currentRound?.currentHole else { return }
        ElevationReadout.shared.updateHole(number: hole.number, green: hole.coordinate)
    }

    private func startPlaygroupChannelIfNeeded(userId: String) {
        guard let round = store.currentRound else { return }
        let holeNumber = round.currentHoleNumber
        Task {
            do {
                guard let pg = try await PlaygroupService.shared.currentOpenPlaygroup() else { return }
                await MainActor.run {
                    // Multiplayer round confirmed → spin up Realtime for
                    // table sync (rounds/strokes/holes/etc.) AND the
                    // playgroup channel for live presence + the shared
                    // scorecard. Solo rounds skip both entirely.
                    // `roundId` points my membership row at this round —
                    // a joiner's row starts with round_id nil, and without
                    // it the shared scorecard can't see me.
                    RealtimeSync.shared.start(forUserId: userId)
                    PlaygroupChannel.shared.start(playgroupId: pg.id, currentHole: holeNumber,
                                                  userId: userId, roundId: round.id)
                }
            } catch {
                dprint("📡 [ActiveRoundView] PlaygroupChannel start check failed: \(error.localizedDescription)")
            }
        }
    }

    func handleCurrentHoleChange() {
        restoreCalculatedMapPosition(force: true)
        // Hold full GPS from arriving at the hole until its first stroke, so
        // the walk from the last green, the tee box, and the tee shot are all
        // captured at a fidelity the elevation fold-in will actually accept.
        // Released in WatchDataStore.addStroke.
        LocationManager.shared.beginTeeHold()
    }

    func handleShowingOptionsChange(_ isShowing: Bool) {
        if !isShowing {
            isMainViewFocused = true
        }
    }

    func handleMinimalScreenModeChange(_ isMinimal: Bool) {
        if !isMinimal {
            restoreCalculatedMapPosition(force: true)
        }
    }
}
