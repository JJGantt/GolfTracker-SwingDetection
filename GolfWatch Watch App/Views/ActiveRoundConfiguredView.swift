import SwiftUI

struct ActiveRoundConfiguredView: View {
    let content: AnyView

    @ObservedObject var store: WatchDataStore
    @ObservedObject var locationManager: LocationManager

    @Binding var showingOptions: Bool
    @Binding var showingEditHole: Bool
    @Binding var showingDistanceEditor: Bool
    @Binding var activeSettingsSheet: ActiveRoundView.SettingsSheet?
    @Binding var isFullViewMode: Bool
    @Binding var manualClubOverride: Bool
    @Binding var navigateToAccelTest: Bool
    @Binding var navigateToViewSettings: Bool
    @Binding var navigateToClubRecommend: Bool
    @Binding var navigateToPredictGreen: Bool
    @Binding var isPlacingPenalty: Bool
    @Binding var minimalScreenMode: Bool
    @Binding var selectedClubIndex: Double

    let currentHole: Hole?
    let distanceToHole: Int?
    let detectedSwingTimestamp: Date?
    let canUndo: Bool

    let dismissParent: () -> Void
    let updateMapPosition: () -> Void
    let updateNoHoleMapPosition: () -> Void
    let deleteLastStroke: () -> Void

    let onViewAppear: () -> Void
    let onViewDisappear: () -> Void
    let onLocationChange: () -> Void
    let onDistanceToHoleChange: (Int?) -> Void
    let onCurrentHoleIndexChange: () -> Void
    let onCurrentHoleChange: () -> Void
    let onShowingOptionsChange: (Bool) -> Void
    let onPlacingPenaltyChange: (Bool) -> Void
    let onMinimalScreenModeChange: (Bool) -> Void
    let onDetectedSwingChange: (Date?) -> Void
    let onSelectedClubIndexChange: () -> Void

    private var contentWithSheets: some View {
        content
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
                    dismissParent: dismissParent,
                    canUndo: canUndo
                )
            }
            .sheet(isPresented: $showingEditHole) {
                if let hole = currentHole {
                    HolePlacementView(store: store, locationManager: locationManager, hole: hole, isEditing: true)
                }
            }
            .sheet(isPresented: $showingDistanceEditor) {
                ClubDistanceEditorView(store: store)
            }
            .sheet(item: $activeSettingsSheet) { sheet in
                settingsSheetView(sheet)
            }
    }

    private var contentWithNavigationRouting: some View {
        contentWithSheets
            .onChange(of: navigateToViewSettings) { _, isActive in
                routeSettingsSheet(.viewSettings, isActive: isActive)
            }
            .onChange(of: navigateToClubRecommend) { _, isActive in
                routeSettingsSheet(.clubRecommend, isActive: isActive)
            }
            .onChange(of: navigateToAccelTest) { _, isActive in
                routeSettingsSheet(.accelTest, isActive: isActive)
            }
            .onChange(of: navigateToPredictGreen) { _, isActive in
                routeSettingsSheet(.predictGreen, isActive: isActive)
            }
    }

    var body: some View {
        contentWithNavigationRouting
            .onAppear(perform: onViewAppear)
            .onDisappear(perform: onViewDisappear)
            .onChange(of: locationManager.location) { _, _ in
                onLocationChange()
            }
            .onChange(of: distanceToHole) { _, newDistance in
                onDistanceToHoleChange(newDistance)
            }
            .onChange(of: store.currentHoleIndex) { _, _ in
                onCurrentHoleIndexChange()
            }
            .onChange(of: store.currentHole) { _, _ in
                onCurrentHoleChange()
            }
            .onChange(of: showingOptions) { _, isShowing in
                onShowingOptionsChange(isShowing)
            }
            .onChange(of: isPlacingPenalty) { _, isPlacing in
                onPlacingPenaltyChange(isPlacing)
            }
            .onChange(of: minimalScreenMode) { _, isMinimal in
                onMinimalScreenModeChange(isMinimal)
            }
            .onChange(of: detectedSwingTimestamp) { _, newValue in
                onDetectedSwingChange(newValue)
            }
            .onChange(of: selectedClubIndex) { _, _ in
                onSelectedClubIndexChange()
            }
    }

    @ViewBuilder
    private func settingsSheetView(_ sheet: ActiveRoundView.SettingsSheet) -> some View {
        switch sheet {
        case .accelTest:
            AccelTestView()
        case .viewSettings:
            ViewSettingsView(
                isFullViewMode: $isFullViewMode,
                updateMapPosition: updateMapPosition,
                updateNoHoleMapPosition: updateNoHoleMapPosition,
                hasCurrentHole: currentHole != nil
            )
        case .clubRecommend:
            ClubRecommendSettingsView(
                store: store,
                manualClubOverride: $manualClubOverride,
                showingDistanceEditor: $showingDistanceEditor
            )
        case .predictGreen:
            PredictGreenSettingsView(store: store)
        }
    }

    private func routeSettingsSheet(_ sheet: ActiveRoundView.SettingsSheet, isActive: Bool) {
        guard isActive else { return }

        switch sheet {
        case .viewSettings:
            navigateToViewSettings = false
        case .clubRecommend:
            navigateToClubRecommend = false
        case .accelTest:
            navigateToAccelTest = false
        case .predictGreen:
            navigateToPredictGreen = false
        }

        activeSettingsSheet = sheet
    }
}
