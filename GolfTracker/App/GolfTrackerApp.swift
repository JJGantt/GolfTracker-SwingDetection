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
                .sheet(isPresented: $motionDataHandler.showingShareSheet) {
                    if let csvURL = motionDataHandler.csvFileURL {
                        ShareSheet(items: [csvURL])
                    }
                }
        }
    }
}

// MARK: - MotionDataHandler

class MotionDataHandler: ObservableObject {
    @Published var showingShareSheet = false
    @Published var csvFileURL: URL?

    init() {
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
        fullCSV += "Threshold: \(String(format: "%.1f", threshold)) G\n"
        fullCSV += "Time Above Threshold: \(String(format: "%.2f", timeAboveThreshold)) s\n"
        fullCSV += "Sample Count: \(sampleCount)\n\n"
        fullCSV += csv

        // Save to temporary file
        let fileName = "motion_data_\(Date().timeIntervalSince1970).csv"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try fullCSV.write(to: tempURL, atomically: true, encoding: .utf8)
            csvFileURL = tempURL
            showingShareSheet = true
            print("📱 [MotionDataHandler] CSV saved to \(tempURL.path)")
        } catch {
            print("📱 [MotionDataHandler] Error saving CSV: \(error)")
        }
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
