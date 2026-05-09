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
    @Binding var navigateToViewSettings: Bool
    @Binding var navigateToClubRecommend: Bool
    @Binding var isPlacingTarget: Bool
    @Binding var minimalScreenMode: Bool
    @Binding var selectedClubIndex: Double

    let currentHole: Hole?
    let distanceToHole: Int?
    let detectedSwingTimestamp: Date?

    let dismissParent: () -> Void
    let updateMapPosition: () -> Void
    let updateNoHoleMapPosition: () -> Void

    let onViewAppear: () -> Void
    let onViewDisappear: () -> Void
    let onLocationChange: () -> Void
    let onDistanceToHoleChange: (Int?) -> Void
    let onCurrentHoleIndexChange: () -> Void
    let onCurrentHoleChange: () -> Void
    let onShowingOptionsChange: (Bool) -> Void
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
                    navigateToViewSettings: $navigateToViewSettings,
                    navigateToClubRecommend: $navigateToClubRecommend,
                    isPlacingTarget: $isPlacingTarget,
                    minimalScreenMode: $minimalScreenMode,
                    updateMapPosition: updateMapPosition,
                    updateNoHoleMapPosition: updateNoHoleMapPosition,
                    dismissParent: dismissParent
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
        }
    }

    private func routeSettingsSheet(_ sheet: ActiveRoundView.SettingsSheet, isActive: Bool) {
        guard isActive else { return }

        switch sheet {
        case .viewSettings:
            navigateToViewSettings = false
        case .clubRecommend:
            navigateToClubRecommend = false
        }

        activeSettingsSheet = sheet
    }
}
