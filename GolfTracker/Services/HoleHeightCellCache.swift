import Foundation
import Supabase

/// In-memory cache of the course's solved height field. Loaded once at round
/// start; read by `ElevationReadout` on every path-sample tick.
///
/// **Source is the `course-height-field` edge function, not the table.** This
/// used to `select()` `hole_height_cells` directly with no range, which
/// PostgREST silently truncates at 1000 rows. Once Hyde Park's map passed that
/// (5107 cells, 2026-08-19), the watch received a fifth of the course and every
/// unreturned cell read as ground nobody had walked — the next round had no
/// elevation readout on any hole, and nothing anywhere reported a problem,
/// because a short read is indistinguishable from a sparse map. The function
/// pages server-side, so completeness is not something this file can forget.
///
/// The function also makes the payload proportional to what it carries: ~10
/// bytes per cell against ~85 as JSON rows (Hyde Park 483 KB -> 76 KB), and
/// `{unchanged:true}` when the client's cached solve stamp is still current.
///
/// Not refreshed mid-round. Other users' rounds folding in during our round
/// won't appear until our next round, which is the acceptable freshness penalty
/// for keeping the read path fast and network-free during play.
///
/// The map is addressed by POSITION, not by hole (migration 00045), so this
/// holds one flat set of cells for the course. It used to group by hole_key,
/// which meant a lookup near a green could miss cells that were sitting a metre
/// away under a neighbouring hole's key.
///
/// `@MainActor` so all access is serialized through the main actor — no need
/// for an NSLock. The fetch and decode run off-actor in `nonisolated` statics;
/// only the dictionary assignment stays on-actor.
@MainActor
final class HoleHeightCellCache {
    static let shared = HoleHeightCellCache()

    /// Indexed by integer cell index, matching `ElevationFoldIn.cellIndex`.
    /// Nil (rather than empty) means "not loaded for a course yet", which the
    /// readout treats as no solution rather than as flat ground.
    private var cells: [ElevationFoldIn.CellKey: ElevationFoldIn.ExistingCell]?

    /// Load the course's field. Safe to call multiple times; replaces prior
    /// cache contents.
    ///
    /// Disk-backed on purpose. The fetch is one shot at round start with no
    /// retry, so a hiccup at the first tee used to mean no readout for the
    /// whole round with no way back. Now a stale-but-real map is preferred to
    /// none: the last good field for this course is adopted first, then
    /// revalidated. Terrain does not move, so an out-of-date field is a good
    /// answer, and only ever off by rounds folded in since.
    func loadForCourse(courseId: UUID) async {
        let cached = await Self.readDisk(courseId: courseId)
        if let cached {
            cells = cached.field
        }

        do {
            let result = try await Self.fetchField(courseId: courseId,
                                                   haveSolvedAt: cached?.solvedAt)
            switch result {
            case .unchanged:
                // Only sent when we supplied a stamp, so `cached` is non-nil
                // and already adopted above.
                ClientEventLogger.log("elevation.field.unchanged", detail: [
                    "courseId": .string(courseId.uuidString),
                    "cellCount": .integer(cells?.count ?? 0)
                ])
            case let .fresh(field, solvedAt, skipped):
                cells = field
                await Self.writeDisk(courseId: courseId, solvedAt: solvedAt, field: field)
                ClientEventLogger.log("elevation.field.loaded", detail: [
                    "courseId": .string(courseId.uuidString),
                    "cellCount": .integer(field.count),
                    "cellsSkipped": .integer(skipped),
                    "solvedAt": .string(solvedAt ?? "none")
                ])
            }
        } catch {
            // Keep whatever the disk gave us. `cells` stays nil only when there
            // was no cached field either, which is the honest "no map" state.
            ClientEventLogger.log("elevation.field.load.failed", detail: [
                "courseId": .string(courseId.uuidString),
                "usingCached": .bool(cells != nil),
                "cellCount": .integer(cells?.count ?? 0),
                "error": .string(String(describing: error).prefix(200).description)
            ])
        }
    }

    /// The cell covering a position, or nil if nothing has been recorded
    /// there. Nil is also returned before any course is loaded.
    func cell(at key: ElevationFoldIn.CellKey) -> ElevationFoldIn.ExistingCell? {
        cells?[key]
    }

    /// The whole map, for callers that want their own indexed copy.
    func snapshot() -> [ElevationFoldIn.CellKey: ElevationFoldIn.ExistingCell] {
        cells ?? [:]
    }

    /// Whether a course has been loaded at all. Distinguishes "no map yet"
    /// from "map exists but nothing near you".
    var isLoaded: Bool { cells != nil }

    /// How many cells the course has. Used for logging and for the
    /// first-tee fidelity hold's "is there anything to sync against" test.
    var count: Int { cells?.count ?? 0 }

    /// Wipe the in-memory cache. Called when a round ends so a fresh round at a
    /// different course doesn't see stale entries. The disk copy survives — it
    /// is keyed by course and is what makes the next round's load resilient.
    func clear() {
        cells = nil
    }

    // MARK: - Fetch

    typealias Field = [ElevationFoldIn.CellKey: ElevationFoldIn.ExistingCell]

    enum FetchResult {
        case unchanged
        case fresh(field: Field, solvedAt: String?, skipped: Int)
    }

    enum FieldError: Error, CustomStringConvertible {
        case http(status: Int, body: String)
        case unsupportedEncoding(String)
        /// The server quantizes on a different grid than `ElevationFoldIn`
        /// does. Every cell would land in the wrong bucket, so refuse the
        /// payload rather than serve a plausible, uniformly wrong map.
        case stepMismatch(server: Double, client: Double)
        case truncatedPayload(bytes: Int)

        var description: String {
            switch self {
            case let .http(status, body): return "http \(status): \(body.prefix(120))"
            case let .unsupportedEncoding(e): return "unsupported encoding \(e)"
            case let .stepMismatch(s, c): return "cell step mismatch server \(s) client \(c)"
            case let .truncatedPayload(b): return "payload not a whole number of cells (\(b) bytes)"
            }
        }
    }

    private struct Envelope: Decodable {
        let solvedAt: String?
        let unchanged: Bool?
        let encoding: String?
        let step: Double?
        let originI: Int?
        let originJ: Int?
        let cellCount: Int?
        let cellsSkipped: Int?
        let cells: String?
    }

    private static let bytesPerCell = 10

    /// One request for the whole field. `haveSolvedAt` is the caller's cached
    /// solve stamp; when it still matches, the server answers `unchanged` and
    /// sends no cells.
    nonisolated static func fetchField(courseId: UUID,
                                       haveSolvedAt: String? = nil) async throws -> FetchResult {
        struct Body: Encodable {
            let courseId: String
            let haveSolvedAt: String?
        }

        let url = SupabaseManager.shared.projectURL
            .appendingPathComponent("functions/v1/course-height-field")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = try await SupabaseManager.shared.client.auth.session
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(Body(courseId: courseId.uuidString,
                                                     haveSolvedAt: haveSolvedAt))
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw FieldError.http(status: status,
                                  body: String(data: data, encoding: .utf8) ?? "")
        }

        let env = try JSONDecoder().decode(Envelope.self, from: data)
        if env.unchanged == true { return .unchanged }

        guard env.encoding == "sparse-v1" else {
            throw FieldError.unsupportedEncoding(env.encoding ?? "none")
        }
        if let step = env.step, step != ElevationFoldIn.cellStepDeg {
            throw FieldError.stepMismatch(server: step, client: ElevationFoldIn.cellStepDeg)
        }

        let field = try decode(base64: env.cells ?? "",
                               originI: env.originI ?? 0,
                               originJ: env.originJ ?? 0)
        return .fresh(field: field, solvedAt: env.solvedAt, skipped: env.cellsSkipped ?? 0)
    }

    /// `sparse-v1`: little-endian, 10 bytes per cell — int16 di, int16 dj,
    /// float32 altM, uint16 n.
    nonisolated private static func decode(base64: String,
                                           originI: Int,
                                           originJ: Int) throws -> Field {
        guard !base64.isEmpty else { return [:] }
        guard let bytes = Data(base64Encoded: base64) else {
            throw FieldError.truncatedPayload(bytes: 0)
        }
        guard bytes.count % bytesPerCell == 0 else {
            throw FieldError.truncatedPayload(bytes: bytes.count)
        }

        let n = bytes.count / bytesPerCell
        var field = Field(minimumCapacity: n)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for k in 0..<n {
                let off = k * bytesPerCell
                let di = Int(raw.loadUnaligned(fromByteOffset: off, as: Int16.self).littleEndian)
                let dj = Int(raw.loadUnaligned(fromByteOffset: off + 2, as: Int16.self).littleEndian)
                let bits = raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self).littleEndian
                let alt = Double(Float(bitPattern: bits))
                let samples = Int(raw.loadUnaligned(fromByteOffset: off + 8, as: UInt16.self).littleEndian)
                let i = originI + di
                let j = originJ + dj
                field[ElevationFoldIn.CellKey(i: i, j: j)] = ElevationFoldIn.ExistingCell(
                    cell_lat: Double(i) * ElevationFoldIn.cellStepDeg,
                    cell_lon: Double(j) * ElevationFoldIn.cellStepDeg,
                    mean_alt_m: alt,
                    n_samples: samples
                )
            }
        }
        return field
    }

    // MARK: - Disk

    private struct DiskCopy {
        let solvedAt: String?
        let field: Field
    }

    /// Stored as the wire envelope rather than as decoded cells: one format to
    /// maintain, and re-decoding 6k cells is far cheaper than the fetch it
    /// replaces.
    private struct DiskEnvelope: Codable {
        let solvedAt: String?
        let originI: Int
        let originJ: Int
        let cells: String
    }

    nonisolated private static func cacheURL(courseId: UUID) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory,
                                                 in: .userDomainMask).first else { return nil }
        let sub = dir.appendingPathComponent("HeightFields", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub.appendingPathComponent("\(courseId.uuidString).json")
    }

    nonisolated private static func readDisk(courseId: UUID) async -> DiskCopy? {
        guard let url = cacheURL(courseId: courseId),
              let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(DiskEnvelope.self, from: data),
              let field = try? decode(base64: env.cells,
                                      originI: env.originI,
                                      originJ: env.originJ),
              !field.isEmpty
        else { return nil }
        return DiskCopy(solvedAt: env.solvedAt, field: field)
    }

    nonisolated private static func writeDisk(courseId: UUID,
                                              solvedAt: String?,
                                              field: Field) async {
        guard let url = cacheURL(courseId: courseId), !field.isEmpty else { return }
        // Re-encode from the decoded field so the disk copy can never disagree
        // with what the readout is using.
        var originI = Int.max
        var originJ = Int.max
        for key in field.keys {
            originI = min(originI, key.i)
            originJ = min(originJ, key.j)
        }
        var bytes = Data(capacity: field.count * bytesPerCell)
        for (key, cell) in field {
            var di = Int16(clamping: key.i - originI).littleEndian
            var dj = Int16(clamping: key.j - originJ).littleEndian
            var alt = Float(cell.mean_alt_m).bitPattern.littleEndian
            var n = UInt16(clamping: cell.n_samples).littleEndian
            withUnsafeBytes(of: &di) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: &dj) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: &alt) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: &n) { bytes.append(contentsOf: $0) }
        }
        let env = DiskEnvelope(solvedAt: solvedAt,
                               originI: originI,
                               originJ: originJ,
                               cells: bytes.base64EncodedString())
        guard let data = try? JSONEncoder().encode(env) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
