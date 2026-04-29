import SwiftUI
import MapKit
import WatchKit

struct ActiveRoundView: View {
    @StateObject var store = WatchDataStore.shared
    @StateObject var locationManager = LocationManager.shared
    @StateObject var swingDetector = SwingDetectionManager.shared
    @StateObject var workoutManager = WorkoutManager.shared
    @ObservedObject var playgroupChannel = PlaygroupChannel.shared
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.dismiss) var dismiss
    @AppStorage("minimalScreenMode") var minimalScreenMode: Bool = false
    @State var selectedClubIndex: Double = 0
    @State var position: MapCameraPosition = .automatic
    @State var showingRecordedFeedback = false
    @State var crownOffset: CGFloat = 0
    @State var isPlacingTarget = false
    @State var isPlacingPenalty = false
    @State var temporaryPenaltyPosition: CLLocationCoordinate2D?
    @State var showingOptions = false
    @State var showingEditHole = false
    @State var isLastStrokeViewMode = false
    @State var undoHoldProgress: Double = 0.0
    @State var undoHoldTimer: Timer?
    // Defaults to full hole view (tee → green) — matches the multiplayer use
    // case (you want to see all players' positions across the hole) and also
    // helps solo players see the whole hole layout up front.
    @State var isFullViewMode = true
    @State var isCrownScrolling = false
    @State var crownScrollTimer: Timer?
    @State var isPulsing = false
    @State var showingDistanceEditor = false
    @State var showingScorecard = false
    @State var manualClubOverride = false       // True when user manually changed club
    @State var onGreenOverride = false          // True when auto-switched to putter for current green
    @State var navigateToAccelTest = false
    @State var navigateToViewSettings = false
    @State var navigateToClubRecommend = false
    @State var navigateToPredictGreen = false

    enum SettingsSheet: String, Identifiable {
        case viewSettings, clubRecommend, accelTest, predictGreen
        var id: String { rawValue }
    }
    @State var activeSettingsSheet: SettingsSheet?
    @State var isAutoSelectingClub = false      // True when we're programmatically updating club
    @State var autoAddedStrokeId: UUID?          // Tracks the auto-added stroke for undo/club update
    @State var overlayClubIndex: Double = 0     // Crown-controlled club shown in auto-add overlay
    @State var lastAutoAddedLocation: CLLocationCoordinate2D?  // GPS of last auto-added stroke for practice replacement
    @FocusState var isMapFocused: Bool
    @FocusState var isMainViewFocused: Bool

    var clubs: [ClubData] {
        return store.availableClubs
    }

    var selectedClub: ClubData? {
        guard !clubs.isEmpty else { return nil }
        let index = Int(selectedClubIndex.rounded()) % clubs.count
        return clubs[index]
    }

    var overlaySelectedClub: ClubData? {
        guard !clubs.isEmpty else { return nil }
        let index = Int(overlayClubIndex.rounded()) % clubs.count
        return clubs[index]
    }

    var crownSelectedClubIndex: Binding<Double> {
        autoAddedStrokeId != nil ? $overlayClubIndex : $selectedClubIndex
    }

    var minimalModeIconName: String {
        minimalScreenMode ? "batteryblock" : "batteryblock.fill"
    }

    var isInteractiveMapMode: Bool {
        isPlacingTarget || isPlacingPenalty
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
        return blob.contains(userCoord)
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
                    // Dim when overlay is open — crown is controlling the overlay club, not this
                    .opacity(autoAddedStrokeId != nil ? 0.35 : 1.0)
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
        .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
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
                // Left: Target button
                VStack(spacing: 4) {
                    // Target button - hide when placing penalty or no hole
                    if !isPlacingPenalty && store.currentHole != nil {
                        Button(action: toggleTargetPlacement) {
                            ZStack {
                                if minimalScreenMode {
                                    Circle()
                                        .fill(Color.black.opacity(0.001))
                                        .frame(width: buttonSize, height: buttonSize)

                                    Circle()
                                        .stroke(Color.white.opacity(0.95), lineWidth: isPlacingTarget ? 2.5 : 2)
                                        .frame(width: buttonSize, height: buttonSize)
                                        .shadow(
                                            color: isPlacingTarget ? Color.yellow.opacity(0.6) : Color.black.opacity(0.25),
                                            radius: isPlacingTarget ? 4 : 2,
                                            x: 0,
                                            y: 0
                                        )

                                    Image(systemName: "scope")
                                        .font(.system(size: iconSize, weight: .bold))
                                        .foregroundColor(.white)
                                } else {
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
                    .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 0.95)

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
                .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
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
        .opacity(isPlacingTarget || isPlacingPenalty ? 0 : 1)
    }

    @ViewBuilder
    func penaltyPlacementButtons(buttonSize: CGFloat, iconSize: CGFloat) -> some View {
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
    func mainContent(geometry: GeometryProxy) -> some View {
        let buttonSize = geometry.size.width * 0.25
        let iconSize = buttonSize * 0.45
        let clubFontSize = geometry.size.width * 0.055
        let needsInteractiveMap = isInteractiveMapMode

        ZStack {
            // Full screen map or black background
            if minimalScreenMode && !needsInteractiveMap {
                Color.black.ignoresSafeArea()
            } else if let hole = store.currentHole {
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

            // Minimal mode toggle (left side, middle)
            VStack {
                Spacer()
                Button(action: {
                    minimalScreenMode.toggle()
                    WKInterfaceDevice.current().play(.click)
                }) {
                    Image(systemName: minimalModeIconName)
                        .font(.system(size: 12))
                        .foregroundColor(minimalScreenMode ? .white : .white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)

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
    var needsFlagPlacement: Bool {
        guard let hole = store.currentHole else { return false }
        return !hole.hasLocation
    }

    var activeRoundContent: some View {
        GeometryReader { geometry in
            mainContent(geometry: geometry)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .focusable()
        .focused($isMainViewFocused)
        .modifier(ClubCrownRotationModifier(selectedClubIndex: crownSelectedClubIndex, clubCount: clubs.count))
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
        ActiveRoundConfiguredView(
            content: AnyView(rootBodyContent),
            store: store,
            locationManager: locationManager,
            showingOptions: $showingOptions,
            showingEditHole: $showingEditHole,
            showingDistanceEditor: $showingDistanceEditor,
            activeSettingsSheet: $activeSettingsSheet,
            isFullViewMode: $isFullViewMode,
            manualClubOverride: $manualClubOverride,
            navigateToAccelTest: $navigateToAccelTest,
            navigateToViewSettings: $navigateToViewSettings,
            navigateToClubRecommend: $navigateToClubRecommend,
            navigateToPredictGreen: $navigateToPredictGreen,
            isPlacingPenalty: $isPlacingPenalty,
            minimalScreenMode: $minimalScreenMode,
            selectedClubIndex: $selectedClubIndex,
            currentHole: store.currentHole,
            distanceToHole: distanceToHole,
            detectedSwingTimestamp: swingDetector.lastDetectedSwing?.timestamp,
            canUndo: canUndo,
            dismissParent: { dismiss() },
            updateMapPosition: { updateMapPosition() },
            updateNoHoleMapPosition: updateNoHoleMapPosition,
            deleteLastStroke: deleteLastStroke,
            onViewAppear: handleViewAppear,
            onViewDisappear: handleViewDisappear,
            onLocationChange: handleLocationChange,
            onDistanceToHoleChange: handleDistanceToHoleChange,
            onCurrentHoleIndexChange: handleCurrentHoleIndexChange,
            onCurrentHoleChange: handleCurrentHoleChange,
            onShowingOptionsChange: handleShowingOptionsChange,
            onPlacingPenaltyChange: handlePlacingPenaltyChange,
            onMinimalScreenModeChange: handleMinimalScreenModeChange,
            onDetectedSwingChange: handleDetectedSwingChange,
            onSelectedClubIndexChange: handleSelectedClubIndexChange
        )
        .sheet(isPresented: $showingScorecard) {
            if let round = store.currentRound {
                ScorecardSheet(round: round)
            }
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

        // Start Realtime ONLY while the active round screen is visible. Drops
        // when the user backs out, so the WebSocket isn't open 24/7.
        if let uid = WatchAuthSession.shared.currentUserId {
            RealtimeSync.shared.start(forUserId: uid)
            startPlaygroupChannelIfNeeded(userId: uid)
        }

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
        autoAddedStrokeId = nil
        locationManager.setGPSPowerMode(.full)
        restoreCalculatedMapPosition(force: true)
        if let uid = WatchAuthSession.shared.currentUserId,
           let round = store.currentRound {
            // Hole index → 1-based hole number (round.currentHoleIndex is 0-based).
            PlaygroupChannel.shared.updateCurrentHole(round.currentHoleIndex + 1, userId: uid)
        }
    }

    private func startPlaygroupChannelIfNeeded(userId: String) {
        guard let round = store.currentRound else { return }
        let holeNumber = round.currentHoleIndex + 1
        Task {
            do {
                guard let pg = try await PlaygroupService.shared.currentOpenPlaygroup() else { return }
                await MainActor.run {
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
        if !isShowing && !isPlacingPenalty {
            isMainViewFocused = true
        }
    }

    func handlePlacingPenaltyChange(_ isPlacing: Bool) {
        if isPlacing {
            restoreCalculatedMapPosition(force: true)
            isMapFocused = true
            isMainViewFocused = false
        } else {
            isMapFocused = false
            isMainViewFocused = true
            restoreCalculatedMapPosition(force: true)
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
                // User location — tinted with the user's playgroup-assigned
                // color (defaults to blue when not in a playgroup).
                if let userLocation = locationManager.location {
                    Annotation("", coordinate: userLocation.coordinate) {
                        let relativeHeading = locationManager.heading ?? 0

                        Image(systemName: "location.north.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Color(hex: store.myPlayerColor))
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
            restoreCalculatedMapPosition(force: true)
        }
    }

    @ViewBuilder
    func standardMapView(for hole: Hole) -> some View {
        // Note: This view is only called when hole.hasLocation is true (via needsFlagPlacement check)
        let holeCoord = hole.coordinate!
        MapReader { proxy in
            Map(position: $position, interactionModes: isInteractiveMapMode ? .all : []) {
                // Hole marker (top) - green if completed, yellow if not
                Annotation("", coordinate: holeCoord) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 20))
                        .foregroundColor(store.isHoleCompleted(hole.number) ? .green : .yellow)
                }

                // User location (bottom) - shows frozen state with white outline, hidden on green (GPS off)
                if let userLocation = locationManager.location, locationManager.gpsPowerMode != .off {
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
                } else if isPlacingPenalty {
                    // Update penalty position
                    temporaryPenaltyPosition = coordinate
                    WKInterfaceDevice.current().play(.click)
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
