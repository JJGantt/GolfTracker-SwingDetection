import SwiftUI

enum TestFileType {
    case motion
    case satellite
}

struct TestFilesView: View {
    @EnvironmentObject var motionDataHandler: MotionDataHandler
    @ObservedObject var satelliteLogHandler = SatelliteLogHandler.shared
    @State private var selectedFiles: Set<UUID> = []
    @State private var showingShareSheet = false
    @State private var filesToShare: [URL] = []
    @State private var selectedType: TestFileType = .satellite

    private var allSelected: Bool {
        switch selectedType {
        case .motion:
            return !motionDataHandler.testFiles.isEmpty && selectedFiles.count == motionDataHandler.testFiles.count
        case .satellite:
            return !satelliteLogHandler.logFiles.isEmpty && selectedFiles.count == satelliteLogHandler.logFiles.count
        }
    }

    var body: some View {
        NavigationStack {
            VStack {
                // Segmented control to switch between types
                Picker("Test Type", selection: $selectedType) {
                    Text("Satellite Logs").tag(TestFileType.satellite)
                    Text("Motion Tests").tag(TestFileType.motion)
                }
                .pickerStyle(.segmented)
                .padding()
                .onChange(of: selectedType) { _ in
                    selectedFiles.removeAll()
                }

                // Debug button for satellite logs
                if selectedType == .satellite {
                    Button("Create Test Log") {
                        createTestLog()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 8)
                }

                if selectedType == .motion {
                    motionTestsView
                } else {
                    satelliteLogsView
                }
            }
            .navigationTitle(selectedType == .motion ? "Motion Tests" : "Satellite Logs")
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: filesToShare)
            }
        }
    }

    private func createTestLog() {
        let testRoundId = UUID()
        satelliteLogHandler.startNewLog(roundId: testRoundId, courseName: "Test Course")
        satelliteLogHandler.log("This is a test log entry")
        satelliteLogHandler.log("Checking if logging system works")
        satelliteLogHandler.log("Current log files count: \(satelliteLogHandler.logFiles.count)")
    }

    @ViewBuilder
    private var motionTestsView: some View {
        if motionDataHandler.testFiles.isEmpty {
            ContentUnavailableView(
                "No Motion Tests",
                systemImage: "waveform"
            )
        } else {
            testFilesList(
                files: motionDataHandler.testFiles.map { TestFileItem(id: $0.id, displayName: $0.displayName) },
                emptyMessage: "No Motion Tests"
            )
        }
    }

    @ViewBuilder
    private var satelliteLogsView: some View {
        if satelliteLogHandler.logFiles.isEmpty {
            ContentUnavailableView(
                "No Satellite Logs",
                systemImage: "globe",
                description: Text("Satellite logs are created when you start a round")
            )
        } else {
            testFilesList(
                files: satelliteLogHandler.logFiles.map { TestFileItem(id: $0.id, displayName: $0.displayName) },
                emptyMessage: "No Satellite Logs"
            )
        }
    }

    @ViewBuilder
    private func testFilesList(files: [TestFileItem], emptyMessage: String) -> some View {
        VStack {
            List {
                ForEach(files.sorted(by: { file1, file2 in
                    // Sort by display name descending (newest first)
                    file1.displayName > file2.displayName
                })) { testFile in
                    HStack {
                        Button(action: {
                            if selectedFiles.contains(testFile.id) {
                                selectedFiles.remove(testFile.id)
                            } else {
                                selectedFiles.insert(testFile.id)
                            }
                        }) {
                            Image(systemName: selectedFiles.contains(testFile.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedFiles.contains(testFile.id) ? .blue : .gray)
                        }
                        .buttonStyle(PlainButtonStyle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text(testFile.displayName)
                                .font(.headline)
                        }
                    }
                }
            }

            // Action buttons at bottom
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: {
                        if allSelected {
                            selectedFiles.removeAll()
                        } else {
                            selectedFiles = Set(files.map { $0.id })
                        }
                    }) {
                        Text(allSelected ? "Unselect All" : "Select All")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 12) {
                    Button(action: shareSelected) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFiles.isEmpty)

                    Button(action: deleteSelected) {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(selectedFiles.isEmpty)
                }
            }
            .padding()
        }
    }

    private func shareSelected() {
        switch selectedType {
        case .motion:
            let selectedTestFiles = motionDataHandler.testFiles.filter { selectedFiles.contains($0.id) }
            filesToShare = selectedTestFiles.map { motionDataHandler.getFileURL(for: $0) }
        case .satellite:
            let selectedLogFiles = satelliteLogHandler.logFiles.filter { selectedFiles.contains($0.id) }
            filesToShare = selectedLogFiles.map { satelliteLogHandler.getFileURL(for: $0) }
        }
        showingShareSheet = true
    }

    private func deleteSelected() {
        switch selectedType {
        case .motion:
            let selectedTestFiles = motionDataHandler.testFiles.filter { selectedFiles.contains($0.id) }
            motionDataHandler.deleteTestFiles(selectedTestFiles)
        case .satellite:
            let selectedLogFiles = satelliteLogHandler.logFiles.filter { selectedFiles.contains($0.id) }
            satelliteLogHandler.deleteLogFiles(selectedLogFiles)
        }
        selectedFiles.removeAll()
    }
}

// Helper struct for unified display
struct TestFileItem: Identifiable {
    let id: UUID
    let displayName: String
}
