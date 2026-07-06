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

    // Calculate the rotation angle for the aim arrow
    @ViewBuilder
    func clubSelectorOverlay(clubFontSize: CGFloat) -> some View {
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
    func clubSelectorOverlayModern(clubFontSize: CGFloat) -> some View {
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
        .opacity(isPlacingTarget ? 0 : 1)
    }

    // MARK: - watchOS 10 Club Selector (inline in button stack)
    @ViewBuilder
    func legacyClubSelector(buttonSize: CGFloat) -> some View {
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
    func buttonsOverlay(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: 4) {
                // Left: Undo button — replaces the target button (target is
                // now in the pull-up Options menu). Standard undo arrow,
                // always red filled, white icon. Tap shows a confirmation
                // popup; confirming pops the most recent stroke. If that
                // stroke was auto-added, also flips its swing_event row to
                // false_positive/high (multi-tap = walk back through the
                // stack). Manual strokes are deletable too — they just
                // don't have an event to label. While target placement is
                // active, this slot becomes a "Done" button so the user
                // can exit target mode.
                VStack(spacing: 4) {
                    if store.currentHole != nil {
                        if isPlacingTarget {
                            Button(action: toggleTargetPlacement) {
                                ZStack {
                                    Circle()
                                        .fill(Color.yellow.opacity(0.95))
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                    Image(systemName: "checkmark")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.black)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .focusable(false)
                        } else {
                            Button(action: { showingUndoConfirmation = true }) {
                                ZStack {
                                    Circle()
                                        .fill(Color.red.opacity(canUndo ? 0.95 : 0.35))
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .focusable(false)
                            .disabled(!canUndo)
                        }
                    }
                }

                Spacer()

                // Right side column
                VStack(spacing: 4) {
                    // watchOS 10: Club selector above the buttons
                    if #unavailable(watchOS 11.0) {
                        if !clubs.isEmpty {
                            legacyClubSelector(buttonSize: buttonSize)
                        }
                    }

                    // Dev data zone — only visible when debug logging is on.
                    // Three lines, no labels (developer reads by position):
                    //   1. steps since last detected swing
                    //   2. false-negative shapes buffered since last stroke
                    //      (these are the rejected paired-shape candidates
                    //      that would upload as a false_negative_group on
                    //      the next manual stroke add)
                    //   3. relative altimeter reading in cm (signed)
                    // Sits above the scorecard button. TimelineView at 1Hz
                    // polls all three values; the rejection buffer isn't
                    // @Published so polling is how the pill stays current.
                    if ClientEventLogger.enabled {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let altCm: Int? = LocationManager.shared.currentRelativeAltitudeMeters.map {
                                Int(($0 * 100).rounded())
                            }
                            VStack(alignment: .center, spacing: 1) {
                                Text("\(swingDetector.stepsSinceLastDetectedSwing)")
                                Text("\(swingDetector.rejectedShapesSinceLastStroke.count)")
                                Text(altCm.map { String(format: "%+d", $0) } ?? "—")
                            }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(minWidth: 30)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.6))
                            )
                        }
                    }

                    // Scorecard button — opens the shared ScorecardView as a sheet.
                    // Sized to match the green plus below it; sits right above it.
                    Button(action: { showingScorecard = true }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.85))
                                .frame(width: buttonSize * 0.7, height: buttonSize * 0.7)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                            Image(systemName: "list.number")
                                .font(.system(size: iconSize * 0.7, weight: .semibold))
                                .foregroundColor(.black)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .focusable(false)
                    .opacity(isPlacingTarget ? 0 : 0.95)

                    // Stroke button
                    VStack(spacing: 4) {
                        // Green stroke button - always show
                        Button(action: recordStroke) {
                            ZStack {
                                if minimalScreenMode {
                                    Circle()
                                        .fill(Color.black.opacity(0.001))
                                        .frame(width: buttonSize, height: buttonSize)

                                    Circle()
                                        .stroke(Color.green.opacity(0.95), lineWidth: 2)
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(
                                            color: Color.green.opacity(showingRecordedFeedback ? 0.45 : 0.25),
                                            radius: showingRecordedFeedback ? 4 : 2,
                                            x: 0,
                                            y: 0
                                        )

                                    Image(systemName: showingRecordedFeedback ? "checkmark" : "plus")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.green)
                                } else {
                                    Circle()
                                        .fill(showingRecordedFeedback ? Color.white.opacity(0.95) : Color.green.opacity(0.95))
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                                    Image(systemName: showingRecordedFeedback ? "checkmark" : "plus")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(showingRecordedFeedback ? .green : .white)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .focusable(false)
                        .disabled(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false)
                        .opacity(store.currentHole.map { store.isHoleCompleted($0.number) } ?? false ? 0.3 : 0.95)
                    }
                }
                .opacity(isPlacingTarget ? 0 : 1)
            }
            .padding(.horizontal, 4)
            .modifier(ButtonsBottomPaddingModifier())
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    var swipeUpIndicator: some View {
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
        .opacity(isPlacingTarget ? 0 : 1)
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
                "currentHoleIndex": .integer(store.currentHoleIndex),
                "holesCount": store.currentRound.map { .integer($0.holes.count) } ?? .null
            ])
        }
        // Ghost-round overlay data — lazy per-hole fetch, re-checked on
        // appear and hole change (toggle-on mid-hole is handled inside
        // the store via its remembered last request). No-ops when
        // disabled or already cached.
        .onAppear { loadGhostForCurrentHole() }
        .onChange(of: store.currentHoleIndex) { _, _ in loadGhostForCurrentHole() }
        // Inbound "X is talking…" pill — small, top-trailing so it doesn't
        // clobber the yardage display at the top center. Hides when no one
        // is speaking, so most of the time it's invisible. The push-to-talk
        // BUTTON itself lives in the pull-up Options menu, not on the map.
        .overlay(alignment: .topTrailing) {
            TalkingBanner()
                .padding(.top, 6)
                .padding(.trailing, 6)
        }
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
            onCurrentHoleIndexChange: handleCurrentHoleIndexChange,
            onCurrentHoleChange: handleCurrentHoleChange,
            onShowingOptionsChange: handleShowingOptionsChange,
            onMinimalScreenModeChange: handleMinimalScreenModeChange,
            onDetectedSwingChange: handleDetectedSwingChange,
            onSelectedClubIndexChange: handleSelectedClubIndexChange
        )
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

    func handleCurrentHoleIndexChange() {
        manualClubOverride = false
        onGreenOverride = false
        lastAutoAddedLocation = nil
        autoAddStack.removeAll()
        locationManager.setGPSPowerMode(.full)
        restoreCalculatedMapPosition(force: true)
        if let uid = WatchAuthSession.shared.currentUserId,
           let round = store.currentRound {
            // Hole index → 1-based hole number (round.currentHoleIndex is 0-based).
            PlaygroupChannel.shared.updateCurrentHole(round.currentHoleIndex + 1, userId: uid)
        }
        pushElevationReadoutHole()
    }

    /// Forward the current hole + green coord into ElevationReadout so
    /// the live Δ-to-green tracks the player's hole. Called on appear
    /// and on every hole change. The "green" we pass is `Hole.coordinate`
    /// (the hole marker — green centroid for OSM rounds, user-placed
    /// pin for manual rounds).
    func pushElevationReadoutHole() {
        guard let round = store.currentRound else { return }
        let sorted = round.holes.sorted { $0.number < $1.number }
        let idx = max(0, min(round.currentHoleIndex, sorted.count - 1))
        guard sorted.indices.contains(idx) else { return }
        let hole = sorted[idx]
        ElevationReadout.shared.updateHole(number: hole.number, green: hole.coordinate)
    }

    private func startPlaygroupChannelIfNeeded(userId: String) {
        guard let round = store.currentRound else { return }
        let holeNumber = round.currentHoleIndex + 1
        Task {
            do {
                guard let pg = try await PlaygroupService.shared.currentOpenPlaygroup() else { return }
                await MainActor.run {
                    // Multiplayer round confirmed → spin up Realtime for
                    // table sync (rounds/strokes/holes/etc.) AND the
                    // playgroup channel for live presence + walkie-talkie.
                    // Solo rounds skip both entirely.
                    RealtimeSync.shared.start(forUserId: userId)
                    PlaygroupChannel.shared.start(playgroupId: pg.id, currentHole: holeNumber, userId: userId)
                }
            } catch {
                dprint("📡 [ActiveRoundView] PlaygroupChannel start check failed: \(error.localizedDescription)")
            }
        }
    }

    func handleCurrentHoleChange() {
        restoreCalculatedMapPosition(force: true)
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

    // MARK: - Map View

    @ViewBuilder
    func mapView(for hole: Hole) -> some View {
        standardMapView(for: hole)
    }

    @ViewBuilder
    func noHoleMapView() -> some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: isInteractiveMapMode ? .all : []) {
                // Breadcrumb trail — small dots behind the user that fade
                // with age. Renders the most-recent slice of pathSamples.
                ForEach(Array(Array(locationManager.pathSamples.suffix(60)).enumerated()), id: \.element.id) { idx, bc in
                    let n = min(locationManager.pathSamples.count, 60)
                    let opacity = 0.08 + 0.55 * Double(idx) / Double(max(n - 1, 1))
                    Annotation("", coordinate: bc.coordinate) {
                        Circle()
                            .fill(Color(hex: store.myPlayerColor))
                            .frame(width: 4, height: 4)
                            .opacity(opacity)
                    }
                }

                // User location — tinted with the user's playgroup-assigned
                // color (defaults to blue when not in a playgroup).
                if let userLocation = locationManager.location {
                    Annotation("", coordinate: userLocation.coordinate) {
                        // Heading is no longer captured (we removed the
                        // tap-to-freeze feature and stopped subscribing to
                        // CMHeading altogether). Render the user as a
                        // direction-less dot in their playgroup color.
                        Circle()
                            .fill(Color(hex: store.myPlayerColor))
                            .frame(width: 7, height: 7)
                            .shadow(color: .white, radius: 2)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                }

                // Stroke markers - show all strokes for current hole even if
                // no hole is defined. Penalty strokes are NOT rendered on the
                // map (the new penalty model is +1 to score with no map
                // marker — the orange "P: N" pill in the overlay is the
                // affordance).
                if let round = store.currentRound {
                    let nextHoleNumber = round.holes.count + 1
                    let strokesForHole = round.strokes
                        .filter { $0.holeNumber == nextHoleNumber && !$0.isPenalty }
                        .sorted { $0.strokeNumber < $1.strokeNumber }
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 20, height: 20)
                                    .opacity(0.85)
                                    .shadow(color: .black, radius: 2)

                                Text("\(stroke.strokeNumber)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.black)
                            }
                        }
                    }
                }

            }
            // Suppress all POI labels (golf course names, businesses, etc).
            // The course geometry (greens, centerline) is what matters; POI
            // text is just clutter on the watch.
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .modifier(HideMapControlsModifier(isInteractive: false))
        }
        .onAppear {
            restoreCalculatedMapPosition(force: true)
        }
    }

    @ViewBuilder
    func standardMapView(for hole: Hole) -> some View {
        // Caller (mainContent) now guards on `hole.hasLocation` before
        // invoking us, so `coordinate` is guaranteed non-nil here. The
        // force-unwrap stays — we want a hard signal if any future caller
        // forgets the pre-check.
        let holeCoord = hole.coordinate!
        // OSM polygon for the current hole's green. White outline only —
        // Apple Maps already renders the green tint underneath, so we
        // don't need our own fill. Source: `filteredGreenCandidates`
        // unifies OSM-derived greens (priority 1) and blob-detection
        // results (priority 2). Either one whose polygon contains the
        // hole's flag becomes the white outline overlay — same rendering
        // for both sources.
        let osmPolygon: [CLLocationCoordinate2D]? = {
            guard let courseId = store.currentRound?.courseId else { return nil }
            return store.filteredGreenCandidates(for: courseId)
                .first { $0.contains(holeCoord) }?
                .polygonCoordinates
        }()
        // OSM hole centerline — the tee→green linestring tagged `golf=hole`.
        // Only rendered when OSM coverage is complete (tier == .full). On
        // partial-tier courses (Sweetwater: 3 holes mapped, refs "1","1","2"
        // for an 18-hole course) the matched centerline is usually
        // misleading or wrong-hole, so we skip it entirely rather than
        // draw a yellow line through the wrong fairway.
        let osmCenterline: [CLLocationCoordinate2D]? = {
            guard let courseId = store.currentRound?.courseId,
                  let osm = store.osmCourseData(forCourseId: courseId),
                  osm.tier == .full else { return nil }
            let match = osm.holes.first { Int($0.ref ?? "") == hole.number }
            guard let pts = match?.centerline, pts.count >= 2 else { return nil }
            return pts.map(\.coordinate)
        }()
        // Putt count for the current hole — drives the centroid label.
        let puttCount: Int = {
            guard let round = store.currentRound else { return 0 }
            return round.strokes.filter { stroke in
                guard stroke.holeNumber == hole.number, !stroke.isPenalty else { return false }
                guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return false }
                return store.getTypeName(for: club) == "Putt"
            }.count
        }()
        // Polygon centroid (mean of vertices) — used to position the putt
        // count label inside the green when present.
        let polygonCentroid: CLLocationCoordinate2D? = {
            guard let pts = osmPolygon, !pts.isEmpty else { return nil }
            let lat = pts.map(\.latitude).reduce(0, +) / Double(pts.count)
            let lon = pts.map(\.longitude).reduce(0, +) / Double(pts.count)
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }()
        return MapReader { proxy in
            Map(position: $position, interactionModes: isInteractiveMapMode ? .all : []) {
                // OSM green polygon — white outline only, no fill (Apple
                // Maps' standard tile already shows the green underneath).
                if let pts = osmPolygon, pts.count >= 3 {
                    MapPolygon(coordinates: pts)
                        .foregroundStyle(.clear)
                        .stroke(.white, lineWidth: 1.5)
                }
                // OSM hole centerline — yellow dashed line tracing the
                // ideal tee→green path. Visually distinct from the white
                // player-trajectory connector that gets drawn from each
                // recorded stroke.
                if let line = osmCenterline {
                    MapPolyline(coordinates: line)
                        .stroke(
                            .yellow.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3])
                        )
                }
                // Ghost round — the previous completed round at this
                // course, rendered UNDER the live content: dim dotted
                // grey walk path + dimmed grey stroke markers with
                // stroke numbers. Distinct from the yellow OSM
                // centerline (dashes) and the white live connector.
                if ghost.enabled {
                    if let ghostPath = ghost.pathByHole[hole.number], ghostPath.count >= 2 {
                        MapPolyline(coordinates: ghostPath)
                            .stroke(
                                .gray.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 4])
                            )
                    }
                    // Same treatment as the live markers: putts filtered
                    // out, each dot labeled with the distance THAT shot
                    // went — to the next non-putt stroke, or (for the
                    // last one) to the first putt.
                    let ghostAll = ghost.strokesByHole[hole.number] ?? []
                    let ghostShots = ghostAll.filter { gs in
                        guard let cid = gs.clubId,
                              let club = store.availableClubs.first(where: { $0.id == cid }) else { return true }
                        return store.getTypeName(for: club) != "Putt"
                    }
                    let ghostFirstPutt = ghostAll.first { gs in
                        guard let cid = gs.clubId,
                              let club = store.availableClubs.first(where: { $0.id == cid }) else { return false }
                        return store.getTypeName(for: club) == "Putt"
                    }?.coordinate
                    ForEach(Array(ghostShots.enumerated()), id: \.element.id) { gi, gs in
                        Annotation("", coordinate: gs.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(.gray.opacity(0.55))
                                    .frame(width: 5, height: 5)
                                let nextCoord: CLLocationCoordinate2D? = gi + 1 < ghostShots.count
                                    ? ghostShots[gi + 1].coordinate
                                    : ghostFirstPutt
                                if let next = nextCoord {
                                    let from = CLLocation(latitude: gs.coordinate.latitude, longitude: gs.coordinate.longitude)
                                    let to = CLLocation(latitude: next.latitude, longitude: next.longitude)
                                    Text("\(Int(from.distance(from: to) * 1.09361))")
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundColor(.gray.opacity(0.85))
                                        .shadow(color: .black, radius: 1.5)
                                        .fixedSize()
                                        .offset(x: 12)
                                }
                            }
                        }
                    }
                }
                // "Putts: N" label rendered just above the green polygon.
                // Hidden at zero. Anchored at the polygon vertex
                // furthest from the user — in the rotated hole-at-top
                // view that's the visually-top edge of the polygon —
                // then offset upward in screen space so the label sits
                // outside the green rather than inside it. Screen-space
                // offset is rotation-independent so this stays above
                // the green regardless of map orientation.
                if puttCount > 0,
                   let pts = osmPolygon, !pts.isEmpty,
                   let userCoord = locationManager.location?.coordinate,
                   let topVertex = pts.max(by: { a, b in
                       let dA = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                           .distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
                       let dB = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                           .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                       return dA < dB
                   }) {
                    Annotation("", coordinate: topVertex) {
                        Text("Putts: \(puttCount)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 2)
                            .offset(y: -14)
                    }
                } else if puttCount > 0, let center = polygonCentroid {
                    // Fallback when no user location yet — render at
                    // centroid with the screen-offset, accepting that
                    // this may overlap the green slightly.
                    Annotation("", coordinate: center) {
                        Text("Putts: \(puttCount)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black, radius: 2)
                    }
                }

                // Breadcrumb trail — small dots behind the user that fade
                // with age. Renders the most-recent slice of pathSamples.
                ForEach(Array(Array(locationManager.pathSamples.suffix(60)).enumerated()), id: \.element.id) { idx, bc in
                    let n = min(locationManager.pathSamples.count, 60)
                    let opacity = 0.08 + 0.55 * Double(idx) / Double(max(n - 1, 1))
                    Annotation("", coordinate: bc.coordinate) {
                        Circle()
                            .fill(Color(hex: store.myPlayerColor))
                            .frame(width: 4, height: 4)
                            .opacity(opacity)
                    }
                }

                // User location dot — direction-less. Heading capture is
                // gone (course-line will eventually drive intended direction);
                // CMHeading subscription is also off, so the previous arrow
                // had no real heading to point with.
                if let userLocation = locationManager.location {
                    Annotation("", coordinate: userLocation.coordinate) {
                        Circle()
                            .fill(Color(hex: store.myPlayerColor))
                            .frame(width: 7, height: 7)
                            .shadow(color: .white, radius: 2)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    }
                }

                // Stroke markers - show only in full view mode
                if isFullViewMode, let round = store.currentRound {
                    // Sort by strokeNumber, not the SwiftData @Relationship
                    // array's natural order — that order is undefined and
                    // shifts as new rows are inserted (especially via
                    // Realtime). Without an explicit sort, `.last` can return
                    // an earlier stroke, breaking the "locked-in yardage
                    // for completed shots, live yardage for the most recent
                    // shot" display logic.
                    //
                    // Putts are intentionally filtered out of the dot+yardage
                    // rendering — putts within the green get visualized via
                    // the centroid putt-count integer instead, since
                    // putt-to-putt yardage isn't meaningful and the dots
                    // would clutter the green. The "last non-putt stroke
                    // shows live distance to user" behavior naturally extends
                    // through the putting phase: while putting, the most
                    // recent non-putt stroke (e.g. the approach from 100yd
                    // out) keeps showing live distance from user position.
                    // Penalty strokes are excluded entirely from the map —
                    // the new penalty model is +1 to score with no marker.
                    let allStrokesForHole = round.strokes
                        .filter { $0.holeNumber == hole.number && !$0.isPenalty }
                        .sorted { $0.strokeNumber < $1.strokeNumber }
                    let strokesForHole = allStrokesForHole.filter { stroke in
                        guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return true }
                        return store.getTypeName(for: club) != "Putt"
                    }
                    // Connector polyline: each non-putt stroke in order, plus
                    // the first putt's location as the terminal endpoint
                    // (if any). The line visually traces "where the ball
                    // went" from tee through approach to the green; the
                    // putt-count integer takes over from there.
                    let firstPuttCoord: CLLocationCoordinate2D? = allStrokesForHole.first { stroke in
                        guard let club = store.availableClubs.first(where: { $0.id == stroke.clubId }) else { return false }
                        return store.getTypeName(for: club) == "Putt"
                    }?.coordinate
                    let connectorCoords: [CLLocationCoordinate2D] = {
                        var coords = strokesForHole.map(\.coordinate)
                        if let putt = firstPuttCoord { coords.append(putt) }
                        return coords
                    }()
                    if connectorCoords.count >= 2 {
                        MapPolyline(coordinates: connectorCoords)
                            .stroke(.white.opacity(0.9), lineWidth: 1.0)
                    }
                    ForEach(Array(strokesForHole.enumerated()), id: \.element.id) { index, stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                // Full view mode - small white circles
                                Circle()
                                    .fill(.white)
                                    .frame(width: 6, height: 6)
                                    .opacity(0.9)
                                    .shadow(color: .black, radius: 2)

                                // Show distance for all strokes in full view mode.
                                // For the LAST stroke (live distance to user),
                                // suppress until the user has moved out of the
                                // practice zone — within ignorePracticeRadius
                                // yards AND below the step gate counts as
                                // "still standing at the ball." Without this
                                // the readout flickers between 0 and small
                                // numbers while the user addresses the shot.
                                let distance: Int? = {
                                    if let lastStroke = strokesForHole.last, stroke.id == lastStroke.id {
                                        guard let userLoc = locationManager.location else { return nil }
                                        let strokeLoc = CLLocation(latitude: stroke.coordinate.latitude, longitude: stroke.coordinate.longitude)
                                        let yards = userLoc.distance(from: strokeLoc) * 1.09361
                                        let withinPracticeRadius = yards < swingDetector.ignorePracticeRadius
                                        let belowStepGate = swingDetector.stepsSinceLastDetectedSwing < swingDetector.stepGateThreshold
                                        if withinPracticeRadius && belowStepGate { return nil }
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

                                // Yardage to LEFT of dot, elevation Δ to
                                // RIGHT. Both rendered as ZStack overlays so
                                // the dot itself stays anchored to the
                                // stroke's coordinate (HStack would shift
                                // the dot off-center as text widths varied).
                                if let dist = distance {
                                    Text("\(dist)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .shadow(color: .black, radius: 2)
                                        .fixedSize()
                                        .offset(x: -18)
                                }
                                ElevationDeltaLabel(coordinate: stroke.coordinate, fontSize: 10)
                                    .fixedSize()
                                    .offset(x: 18)
                            }
                        }
                    }
                }

                // Other players' strokes for the current hole, in their color
                // at 60% alpha. Lines connect each player's strokes in order.
                let myUid = WatchAuthSession.shared.currentUserId
                ForEach(playgroupChannel.members.filter { $0.userId != myUid }, id: \.userId) { member in
                    let strokes = playgroupChannel.otherStrokes[member.userId] ?? []
                    let color = Color(hex: member.color ?? PlaygroupService.playerPalette[0])
                    if strokes.count >= 2 {
                        MapPolyline(coordinates: strokes.map { $0.coordinate })
                            .stroke(color.opacity(0.45), lineWidth: 2)
                    }
                    ForEach(strokes) { stroke in
                        Annotation("", coordinate: stroke.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(color.opacity(0.6))
                                    .frame(width: 12, height: 12)
                                Text("\(stroke.strokeNumber)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }

                // Other players' live GPS dots from presence.
                ForEach(Array(playgroupChannel.presence.values.filter { $0.userId != myUid }), id: \.userId) { p in
                    let color = Color(hex: playgroupChannel.color(for: p.userId))
                    Annotation("", coordinate: p.coordinate) {
                        ZStack {
                            Circle().stroke(color, lineWidth: 2).frame(width: 14, height: 14)
                            Circle().fill(color).frame(width: 7, height: 7)
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
                                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                                        Text("\(distance)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.black)
                                        ElevationDeltaLabel(coordinate: target, fontSize: 9)
                                    }
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

            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .modifier(HideMapControlsModifier(isInteractive: isPlacingTarget))
            .allowsHitTesting(isPlacingTarget)
            .focusable(isPlacingTarget)
            .focused($isMapFocused)
            .onAppear {
                restoreCalculatedMapPosition(force: true)
            }
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
                        ClientEventLogger.log("targetTap.delete", detail: ["index": .integer(indexToDelete), "before": .integer(coords.count)])
                        coords.remove(at: indexToDelete)
                        targetCoordinatesBinding.wrappedValue = coords
                        ClientEventLogger.log("targetTap.delete.afterBindingSet", detail: ["after": .integer(coords.count)])
                        WKInterfaceDevice.current().play(.click)
                    } else {
                        ClientEventLogger.log("targetTap.add", detail: ["before": .integer(coords.count)])
                        coords.append(coordinate)
                        targetCoordinatesBinding.wrappedValue = coords
                        WKInterfaceDevice.current().play(.success)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    func toggleTargetPlacement() {
        isPlacingTarget.toggle()
        WKInterfaceDevice.current().play(.click)

        // When exiting target mode, reposition map
        if !isPlacingTarget {
            isMapFocused = false
            isMainViewFocused = true
            // Force immediate map update when exiting target mode
            DispatchQueue.main.async {
                restoreCalculatedMapPosition(force: true)
            }
        } else {
            restoreCalculatedMapPosition(force: true)
            isMapFocused = true
            isMainViewFocused = false
        }
    }

    func restoreCalculatedMapPosition(force: Bool = false) {
        if store.currentHole != nil {
            updateMapPosition(force: force)
        } else {
            updateNoHoleMapPosition()
        }
    }

    func updateMapPosition(force: Bool = false) {
        guard force || !isInteractiveMapMode else { return }

        guard let hole = store.currentHole,
              let holeCoord = hole.coordinate else { return }

        // Determine start coordinate based on view mode.
        // Full-view priority order:
        //   1. OSM hole centerline tee point (when available) — pinned tee
        //      box → flag is the most stable framing across the round and
        //      doesn't shift as strokes get added
        //   2. First recorded stroke — pre-OSM fallback for courses without
        //      hole data
        //   3. User location — last resort if there's no stroke and no OSM
        let startCoord: CLLocationCoordinate2D
        if isFullViewMode {
            let osmTee: CLLocationCoordinate2D? = {
                guard let courseId = store.currentRound?.courseId,
                      let osm = store.osmCourseData(forCourseId: courseId),
                      osm.tier == .full else { return nil }
                let match = osm.holes.first { Int($0.ref ?? "") == hole.number }
                return match?.centerline.first?.coordinate
            }()
            if let tee = osmTee {
                startCoord = tee
            } else if let first = firstStroke {
                startCoord = first.coordinate
            } else if let userLocation = locationManager.location {
                startCoord = userLocation.coordinate
            } else {
                return
            }
        } else if let userLocation = locationManager.location {
            startCoord = userLocation.coordinate
        } else {
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

    func updateNoHoleMapPosition() {
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

    func calculateBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDirection {
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

    func calculateCrownOffset(screenHeight: CGFloat) {
        crownOffset = screenHeight * 0.1
    }
}

// MARK: - Club Distance Editor View

struct ClubDistanceEditorView: View {
    @ObservedObject var store: WatchDataStore
    @Environment(\.dismiss) private var dismiss
    @State var selectedIndex: Int = 0
    @State var editingDistance: Double = 100
    @FocusState var isCrownFocused: Bool

    // Get enabled clubs with their type names (excludes clubs not eligible for prediction)
    var enabledClubs: [(club: ClubData, typeName: String)] {
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

    var currentClubName: String {
        guard selectedIndex < enabledClubs.count else { return "" }
        return enabledClubs[selectedIndex].typeName
    }

    var currentDistance: Int {
        Int(editingDistance.rounded())
    }

    var isCurrentClubDisabled: Bool {
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

    func loadCurrentClubDistance() {
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

    func saveCurrentDistance() {
        guard selectedIndex < enabledClubs.count else { return }
        let typeName = enabledClubs[selectedIndex].typeName
        var averages = store.customClubAverages
        averages[typeName] = currentDistance
        store.customClubAverages = averages
    }

    func previousClub() {
        guard selectedIndex > 0 else { return }
        saveCurrentDistance()
        selectedIndex -= 1
        loadCurrentClubDistance()
        WKInterfaceDevice.current().play(.click)
    }

    func nextClub() {
        guard selectedIndex < enabledClubs.count - 1 else { return }
        saveCurrentDistance()
        selectedIndex += 1
        loadCurrentClubDistance()
        WKInterfaceDevice.current().play(.click)
    }

    func toggleClubDisabled() {
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
