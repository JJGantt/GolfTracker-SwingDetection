import SwiftUI

struct TestFilesView: View {
    @EnvironmentObject var motionDataHandler: MotionDataHandler
    @State private var selectedFiles: Set<UUID> = []
    @State private var showingShareSheet = false
    @State private var filesToShare: [URL] = []

    private var allSelected: Bool {
        !motionDataHandler.testFiles.isEmpty && selectedFiles.count == motionDataHandler.testFiles.count
    }

    var body: some View {
        NavigationStack {
            VStack {
                if motionDataHandler.testFiles.isEmpty {
                    ContentUnavailableView(
                        "No Test Files",
                        systemImage: "waveform"
                    )
                } else {
                    List {
                        ForEach(motionDataHandler.testFiles.sorted(by: { $0.date > $1.date })) { testFile in
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
                                    selectedFiles = Set(motionDataHandler.testFiles.map { $0.id })
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
            .navigationTitle("Motion Tests")
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: filesToShare)
            }
        }
    }

    private func shareSelected() {
        let selectedTestFiles = motionDataHandler.testFiles.filter { selectedFiles.contains($0.id) }
        filesToShare = selectedTestFiles.map { motionDataHandler.getFileURL(for: $0) }
        showingShareSheet = true
    }

    private func deleteSelected() {
        let selectedTestFiles = motionDataHandler.testFiles.filter { selectedFiles.contains($0.id) }
        motionDataHandler.deleteTestFiles(selectedTestFiles)
        selectedFiles.removeAll()
    }
}
