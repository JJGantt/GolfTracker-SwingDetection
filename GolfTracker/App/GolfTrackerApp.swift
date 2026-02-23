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
        let dateStr = formatter.string(from: date)
        // Strip timestamp suffix and extension to get a readable label
        let base = fileName
            .replacingOccurrences(of: #"_\d{10,}(\.\w+)?$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
        if sampleCount > 0 {
            return "\(dateStr) — \(base) (\(sampleCount))"
        } else {
            return "\(dateStr) — \(base)"
        }
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
        WatchConnectivityManager.shared.onReceiveMotionData = { [weak self] csv, sampleCount, threshold, timeAboveThreshold, rawAccelCsv, rawAccelSampleCount in
            print("📱 [MotionDataHandler] Received DeviceMotion: \(sampleCount) samples, RawAccel: \(rawAccelSampleCount ?? 0) samples")
            self?.handleMotionData(csv: csv, sampleCount: sampleCount, threshold: threshold, timeAboveThreshold: timeAboveThreshold, rawAccelCsv: rawAccelCsv, rawAccelSampleCount: rawAccelSampleCount)
        }

        WatchConnectivityManager.shared.onReceivePuttEventData = { [weak self] csv, sampleCount, rawAccelCsv, rawAccelSampleCount, outcome in
            print("📱 [MotionDataHandler] Received putt attempt (\(outcome)): \(sampleCount) DeviceMotion, \(rawAccelSampleCount ?? 0) RawAccel samples")
            self?.handlePuttEventData(csv: csv, sampleCount: sampleCount, rawAccelCsv: rawAccelCsv, rawAccelSampleCount: rawAccelSampleCount, outcome: outcome)
        }

        WatchConnectivityManager.shared.onReceivePuttDiagnosticLog = { [weak self] log, outcome, finalState in
            print("📱 [MotionDataHandler] Received putt diagnostic log: outcome=\(outcome)")
            self?.handlePuttDiagnosticLog(log: log, outcome: outcome, finalState: finalState)
        }

        WatchConnectivityManager.shared.onReceiveMotionFile = { [weak self] url, metadata in
            print("📱 [MotionDataHandler] Received motion file transfer: \(url.lastPathComponent)")
            self?.handleMotionFile(url: url, metadata: metadata)
        }
    }

    private func handleMotionData(csv: String, sampleCount: Int, threshold: Double, timeAboveThreshold: Double, rawAccelCsv: String?, rawAccelSampleCount: Int?) {
        let timestamp = Date().timeIntervalSince1970

        // Save device motion CSV (100Hz)
        var fullCSV = "Golf Swing Motion Data (Device Motion @ 100Hz)\n"
        fullCSV += "Sample Count: \(sampleCount)\n\n"
        fullCSV += csv

        let fileName = "motion_test_\(timestamp).csv"
        let fileURL = testFilesDirectory.appendingPathComponent(fileName)

        do {
            try fullCSV.write(to: fileURL, atomically: true, encoding: .utf8)

            // Create metadata entry for device motion
            let testFile = MotionTestFile(
                id: UUID(),
                date: Date(),
                sampleCount: sampleCount,
                fileName: fileName
            )

            testFiles.append(testFile)
            print("📱 [MotionDataHandler] Device Motion CSV saved to \(fileURL.path)")
        } catch {
            print("📱 [MotionDataHandler] Error saving Device Motion CSV: \(error)")
        }

        // Save raw accelerometer CSV (800Hz) if available
        if let rawCsv = rawAccelCsv, let rawCount = rawAccelSampleCount, rawCount > 0 {
            var fullRawCSV = "Golf Swing Raw Accelerometer Data (@ 800Hz)\n"
            fullRawCSV += "Sample Count: \(rawCount)\n\n"
            fullRawCSV += rawCsv

            let rawFileName = "raw_accel_\(timestamp).csv"
            let rawFileURL = testFilesDirectory.appendingPathComponent(rawFileName)

            do {
                try fullRawCSV.write(to: rawFileURL, atomically: true, encoding: .utf8)

                // Create metadata entry for raw accelerometer
                let rawTestFile = MotionTestFile(
                    id: UUID(),
                    date: Date(),
                    sampleCount: rawCount,
                    fileName: rawFileName
                )

                testFiles.append(rawTestFile)
                print("📱 [MotionDataHandler] Raw Accelerometer CSV saved to \(rawFileURL.path)")
            } catch {
                print("📱 [MotionDataHandler] Error saving Raw Accelerometer CSV: \(error)")
            }
        }

        saveTestFiles()
    }

    private func handlePuttEventData(csv: String, sampleCount: Int, rawAccelCsv: String?, rawAccelSampleCount: Int?, outcome: String) {
        let timestamp = Date().timeIntervalSince1970
        let label = outcome == "detected" ? "putt_event" : "putt_fail"

        // Save device motion CSV
        var fullCSV = "Putt \(outcome == "detected" ? "Detected" : "Failed") (Device Motion @ 100Hz)\n"
        fullCSV += "Outcome: \(outcome)\n"
        fullCSV += "Sample Count: \(sampleCount)\n\n"
        fullCSV += csv

        let fileName = "\(label)_\(timestamp).csv"
        let fileURL = testFilesDirectory.appendingPathComponent(fileName)

        do {
            try fullCSV.write(to: fileURL, atomically: true, encoding: .utf8)
            let testFile = MotionTestFile(id: UUID(), date: Date(), sampleCount: sampleCount, fileName: fileName)
            testFiles.append(testFile)
            print("📱 [MotionDataHandler] Putt \(outcome) Device Motion CSV saved to \(fileURL.path)")
        } catch {
            print("📱 [MotionDataHandler] Error saving putt Device Motion CSV: \(error)")
        }

        // Save raw accelerometer CSV if available
        if let rawCsv = rawAccelCsv, let rawCount = rawAccelSampleCount, rawCount > 0 {
            var fullRawCSV = "Putt \(outcome == "detected" ? "Detected" : "Failed") (Raw Accelerometer @ 800Hz)\n"
            fullRawCSV += "Outcome: \(outcome)\n"
            fullRawCSV += "Sample Count: \(rawCount)\n\n"
            fullRawCSV += rawCsv

            let rawFileName = "\(label)_raw_\(timestamp).csv"
            let rawFileURL = testFilesDirectory.appendingPathComponent(rawFileName)

            do {
                try fullRawCSV.write(to: rawFileURL, atomically: true, encoding: .utf8)
                let rawTestFile = MotionTestFile(id: UUID(), date: Date(), sampleCount: rawCount, fileName: rawFileName)
                testFiles.append(rawTestFile)
                print("📱 [MotionDataHandler] Putt \(outcome) Raw Accel CSV saved to \(rawFileURL.path)")
            } catch {
                print("📱 [MotionDataHandler] Error saving putt Raw Accel CSV: \(error)")
            }
        }

        saveTestFiles()
    }

    private func handlePuttDiagnosticLog(log: String, outcome: String, finalState: String) {
        let timestamp = Date().timeIntervalSince1970

        var content = "Putt Detection Diagnostic Log\n"
        content += "Outcome: \(outcome)\n"
        content += "Final State: \(finalState)\n"
        content += "Time: \(Date())\n"
        content += "═══════════════════════════════════════\n\n"
        content += log

        let fileName = "putt_diag_\(outcome)_\(timestamp).txt"
        let fileURL = testFilesDirectory.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            let entryCount = log.components(separatedBy: "\n").count
            let testFile = MotionTestFile(
                id: UUID(),
                date: Date(),
                sampleCount: entryCount,
                fileName: fileName
            )

            testFiles.append(testFile)
            saveTestFiles()
            print("📱 [MotionDataHandler] Putt diagnostic log saved: \(fileName)")
        } catch {
            print("📱 [MotionDataHandler] Error saving putt diagnostic log: \(error)")
        }
    }

    private func handleMotionFile(url: URL, metadata: [String: Any]) {
        let fileType = metadata["type"] as? String ?? ""
        let dataType = metadata["dataType"] as? String ?? "deviceMotion"
        let sampleCount = metadata["sampleCount"] as? Int ?? 0
        let outcome = metadata["outcome"] as? String
        let finalState = metadata["finalState"] as? String ?? ""
        let timestamp = Date().timeIntervalSince1970

        // Determine file prefix and header based on type/dataType
        let (prefix, header): (String, String)
        switch (fileType, dataType) {
        case ("motionData", "deviceMotion"):
            prefix = "motion_test"
            header = "Golf Swing Motion Data (Device Motion @ 100Hz)\nSample Count: \(sampleCount)\n\n"
        case ("motionData", "rawAccel"):
            prefix = "raw_accel"
            header = "Golf Swing Raw Accelerometer Data (@ 800Hz)\nSample Count: \(sampleCount)\n\n"
        case ("puttEventData", "deviceMotion"):
            let tag = outcome == "detected" ? "Detected" : "Failed"
            prefix = outcome == "detected" ? "putt_event" : "putt_fail"
            header = "Putt \(tag) (Device Motion @ 100Hz)\nOutcome: \(outcome ?? "unknown")\nSample Count: \(sampleCount)\n\n"
        case ("puttEventData", "rawAccel"):
            prefix = (outcome == "detected" ? "putt_event" : "putt_fail") + "_raw"
            header = "Putt \(outcome == "detected" ? "Detected" : "Failed") (Raw Accelerometer @ 800Hz)\nOutcome: \(outcome ?? "unknown")\nSample Count: \(sampleCount)\n\n"
        case ("continuousLog", _):
            prefix = "continuous_log"
            header = ""
        default:
            print("📱 [MotionDataHandler] Unknown file type '\(fileType)/\(dataType)', skipping")
            return
        }

        let ext = fileType == "continuousLog" ? "txt" : "csv"
        let fileName = "\(prefix)_\(Int(timestamp)).\(ext)"
        let destURL = testFilesDirectory.appendingPathComponent(fileName)

        do {
            let csvContent = try String(contentsOf: url, encoding: .utf8)
            try (header + csvContent).write(to: destURL, atomically: true, encoding: .utf8)
            let testFile = MotionTestFile(id: UUID(), date: Date(), sampleCount: sampleCount, fileName: fileName)
            testFiles.append(testFile)
            saveTestFiles()
            print("📱 [MotionDataHandler] Saved \(fileName) (\(sampleCount) samples)")
        } catch {
            print("📱 [MotionDataHandler] Error saving motion file \(fileName): \(error)")
        }

        // If a diagnostic log was bundled in the metadata, save it as a separate file
        if fileType == "puttEventData", dataType == "deviceMotion",
           let diagLog = metadata["diagnosticLog"] as? String, !diagLog.isEmpty {
            handlePuttDiagnosticLog(log: diagLog, outcome: outcome ?? "unknown", finalState: finalState)
        }

        // Clean up the temp copy
        try? FileManager.default.removeItem(at: url)
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

// MARK: - SatelliteLogFile

struct SatelliteLogFile: Identifiable, Codable {
    let id: UUID
    let date: Date
    let roundId: UUID
    let courseName: String
    let fileName: String

    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "\(formatter.string(from: date)) - \(courseName)"
    }
}

// MARK: - SatelliteLogHandler

class SatelliteLogHandler: ObservableObject {
    static let shared = SatelliteLogHandler()

    @Published var logFiles: [SatelliteLogFile] = []

    private let logFilesDirectory: URL
    private let metadataURL: URL
    private var currentLogFile: URL?
    private var currentRoundId: UUID?

    init() {
        // Create log files directory in Documents
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFilesDirectory = documentsDirectory.appendingPathComponent("SatelliteLogs")
        metadataURL = documentsDirectory.appendingPathComponent("satellite_logs_metadata.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: logFilesDirectory, withIntermediateDirectories: true)

        // Load existing log files
        loadLogFiles()
    }

    func startNewLog(roundId: UUID, courseName: String) {
        print("🚀🚀🚀 [SatelliteLogHandler] startNewLog called for \(courseName)")

        // Create new log file for this round
        let fileName = "satellite_log_\(Date().timeIntervalSince1970).txt"
        let fileURL = logFilesDirectory.appendingPathComponent(fileName)
        currentLogFile = fileURL
        currentRoundId = roundId

        print("🚀 [SatelliteLogHandler] Log file path: \(fileURL.path)")

        // Write header
        let header = """
        ═══════════════════════════════════════════════════════
        SATELLITE IMAGERY LOG
        ═══════════════════════════════════════════════════════
        Round Started: \(Date())
        Course: \(courseName)
        Round ID: \(roundId)
        ═══════════════════════════════════════════════════════


        """

        do {
            try header.write(to: fileURL, atomically: true, encoding: .utf8)
            print("🚀 [SatelliteLogHandler] Successfully wrote log file header")
        } catch {
            print("❌ [SatelliteLogHandler] Failed to write log file: \(error)")
        }

        // Create metadata entry
        let logFile = SatelliteLogFile(
            id: UUID(),
            date: Date(),
            roundId: roundId,
            courseName: courseName,
            fileName: fileName
        )

        logFiles.append(logFile)
        print("🚀 [SatelliteLogHandler] Added to logFiles array, now have \(logFiles.count) logs")

        saveLogFiles()
        print("🚀 [SatelliteLogHandler] Saved log files metadata")

        log("📱 Satellite log started for round on \(courseName)")
    }

    func log(_ message: String) {
        guard let fileURL = currentLogFile else {
            print("❌ [SatelliteLogHandler] log() called but currentLogFile is nil!")
            return
        }

        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)\n"

        // Append to file
        do {
            if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                fileHandle.seekToEndOfFile()
                if let data = logEntry.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } else {
                // File doesn't exist, create it with this entry
                try logEntry.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("❌ [SatelliteLogHandler] Failed to write log entry: \(error)")
        }

        // Also print to console for debugging in Xcode
        print(message)
    }

    func getFileURL(for logFile: SatelliteLogFile) -> URL {
        return logFilesDirectory.appendingPathComponent(logFile.fileName)
    }

    func deleteLogFiles(_ logFilesToDelete: [SatelliteLogFile]) {
        for logFile in logFilesToDelete {
            let fileURL = getFileURL(for: logFile)
            try? FileManager.default.removeItem(at: fileURL)
            logFiles.removeAll { $0.id == logFile.id }
        }
        saveLogFiles()
    }

    private func loadLogFiles() {
        guard let data = try? Data(contentsOf: metadataURL),
              let files = try? JSONDecoder().decode([SatelliteLogFile].self, from: data) else {
            return
        }
        logFiles = files
    }

    private func saveLogFiles() {
        guard let data = try? JSONEncoder().encode(logFiles) else { return }
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
