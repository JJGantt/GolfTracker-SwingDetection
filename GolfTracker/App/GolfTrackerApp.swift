//
//  GolfTrackerApp.swift
//  GolfTracker
//
//  Created by Jared gantt on 12/2/25.
//

import SwiftUI

@main
struct GolfTrackerApp: App {
    @StateObject private var store = DataStore()
    @StateObject private var motionDataHandler = MotionDataHandler()

    init() {
        print("🚀🚀🚀 APP LAUNCHED - GolfTracker is starting! 🚀🚀🚀")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(motionDataHandler)
        }
    }
}

// MARK: - MotionTestFile

struct MotionTestFile: Identifiable, Codable {
    let id: UUID
    let date: Date
    let sampleCount: Int
    let fileName: String

    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "\(formatter.string(from: date)) - \(sampleCount) samples"
    }
}

// MARK: - MotionDataHandler

class MotionDataHandler: ObservableObject {
    @Published var testFiles: [MotionTestFile] = []

    private let testFilesDirectory: URL
    private let metadataURL: URL

    init() {
        // Create test files directory in Documents
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        testFilesDirectory = documentsDirectory.appendingPathComponent("MotionTests")
        metadataURL = documentsDirectory.appendingPathComponent("motion_tests_metadata.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: testFilesDirectory, withIntermediateDirectories: true)

        // Load existing test files
        loadTestFiles()

        setupWatchConnectivity()
    }

    private func setupWatchConnectivity() {
        WatchConnectivityManager.shared.onReceiveMotionData = { [weak self] csv, sampleCount, threshold, timeAboveThreshold in
            print("📱 [MotionDataHandler] Received \(sampleCount) samples")
            self?.handleMotionData(csv: csv, sampleCount: sampleCount, threshold: threshold, timeAboveThreshold: timeAboveThreshold)
        }
    }

    private func handleMotionData(csv: String, sampleCount: Int, threshold: Double, timeAboveThreshold: Double) {
        // Add metadata to CSV
        var fullCSV = "Golf Swing Motion Data\n"
        fullCSV += "Sample Count: \(sampleCount)\n\n"
        fullCSV += csv

        // Save to persistent file
        let fileName = "motion_test_\(Date().timeIntervalSince1970).csv"
        let fileURL = testFilesDirectory.appendingPathComponent(fileName)

        do {
            try fullCSV.write(to: fileURL, atomically: true, encoding: .utf8)

            // Create metadata entry
            let testFile = MotionTestFile(
                id: UUID(),
                date: Date(),
                sampleCount: sampleCount,
                fileName: fileName
            )

            testFiles.append(testFile)
            saveTestFiles()

            print("📱 [MotionDataHandler] CSV saved to \(fileURL.path)")
        } catch {
            print("📱 [MotionDataHandler] Error saving CSV: \(error)")
        }
    }

    func getFileURL(for testFile: MotionTestFile) -> URL {
        return testFilesDirectory.appendingPathComponent(testFile.fileName)
    }

    func deleteTestFiles(_ testFilesToDelete: [MotionTestFile]) {
        for testFile in testFilesToDelete {
            let fileURL = getFileURL(for: testFile)
            try? FileManager.default.removeItem(at: fileURL)
            testFiles.removeAll { $0.id == testFile.id }
        }
        saveTestFiles()
    }

    private func loadTestFiles() {
        guard let data = try? Data(contentsOf: metadataURL),
              let files = try? JSONDecoder().decode([MotionTestFile].self, from: data) else {
            return
        }
        testFiles = files
    }

    private func saveTestFiles() {
        guard let data = try? JSONEncoder().encode(testFiles) else { return }
        try? data.write(to: metadataURL)
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
