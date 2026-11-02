import XCTest

/// Numbers the app and the server code must agree on, read from each file's
/// source. The client folds a round into the same 3 m cells the server solves
/// and serves, and cuts the drive home at the same speed: if either side
/// moves alone, the client writes cells the server re-solve then discards.
final class SharedConstantsTests: XCTestCase {

    private let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String? {
        let url = repo.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func number(_ pattern: String, in text: String, file: String) throws -> Double {
        let regex = try NSRegularExpression(pattern: pattern)
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text), let v = Double(text[r]) else {
            XCTFail("\(pattern) not found in \(file)"); return .nan
        }
        return v
    }

    func testClientAndServerAgreeOnTheCellGridAndTheVehicleCut() throws {
        let client = try XCTUnwrap(source("GolfTracker/Services/ElevationFoldIn.swift"))
        let field = try XCTUnwrap(source("supabase/functions/course-height-field/index.ts"))
        let step = try number(#"static let cellStepDeg: Double = ([0-9.eE-]+)"#, in: client, file: "ElevationFoldIn")
        XCTAssertEqual(try number(#"const CELL_STEP_DEG = ([0-9.eE-]+)"#, in: field, file: "course-height-field"), step)

        // The solver is in the private algorithms submodule, absent from a
        // checkout without access to it (and so from CI).
        guard let solver = try source("StrokeSaverAlgorithms/supabase/functions/resolve-hole-heights/solver.ts") else {
            throw XCTSkip("algorithms submodule not checked out")
        }
        XCTAssertEqual(try number(#"export const CELL_STEP_DEG = ([0-9.eE-]+)"#, in: solver, file: "solver.ts"), step)
        XCTAssertEqual(try number(#"export const VEHICLE_SPEED_MPS = ([0-9.]+)"#, in: solver, file: "solver.ts"),
                       try number(#"static let vehicleSpeedMps: Double = ([0-9.]+)"#, in: client, file: "ElevationFoldIn"))
        XCTAssertEqual(try number(#"export const VEHICLE_WINDOW_SECONDS = ([0-9.]+)"#, in: solver, file: "solver.ts"),
                       try number(#"static let vehicleWindowSeconds: TimeInterval = ([0-9.]+)"#, in: client, file: "ElevationFoldIn"))
    }
}
