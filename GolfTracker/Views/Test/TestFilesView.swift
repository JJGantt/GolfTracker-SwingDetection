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
                        "No Motion Tests",
                        systemImage: "waveform"
                    )
                } else {
                    testFilesList(
                        files: motionDataHandler.testFiles.map { TestFileItem(id: $0.id, displayName: $0.displayName, fileURL: motionDataHandler.getFileURL(for: $0)) }
                    )
                }
            }
            .navigationTitle("Motion Tests")
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: filesToShare)
            }
        }
    }

    @ViewBuilder
    private func testFilesList(files: [TestFileItem]) -> some View {
        VStack {
            List {
                ForEach(files.sorted(by: { file1, file2 in
                    // Sort by display name descending (newest first)
                    file1.displayName > file2.displayName
                })) { testFile in
                    NavigationLink(destination: LogFileDetailView(fileURL: testFile.fileURL, fileName: testFile.displayName)) {
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

// Helper struct for unified display
struct TestFileItem: Identifiable {
    let id: UUID
    let displayName: String
    let fileURL: URL
}

struct LogFileDetailView: View {
    let fileURL: URL
    let fileName: String
    @State private var content: String = ""

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do {
                content = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                content = "Error reading file: \(error.localizedDescription)"
            }
        }
    }
}
