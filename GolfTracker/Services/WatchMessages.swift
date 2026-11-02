import Foundation

// What the phone and the watch say to each other over WatchConnectivity, as
// types. Compiled into both targets.
//
// The wire format is the plist dictionary every installed build already sends
// and reads: a `type` key naming the message, the payload's fields beside it
// under the same keys and value types as always (UUIDs as strings, times as
// seconds since 1970). The phone and the watch update separately, so either
// side may be talking to an older build; a change here has to keep reading
// what an older build sends and keep sending what it reads.
// `Tests/AppLogic`'s `WatchMessagesTests` pins the dictionaries.

/// Where the iPhone is with a blob analysis the watch asked for.
enum HoleDetectionPhoneState: String, Codable, Sendable {
    /// Received while the app was not on screen. It runs on the next
    /// foreground — MapKit snapshots do not render reliably in the background.
    case queued
    case running
    /// Results are in the server cache (and on their way over WC).
    case done
    case failed
}

// MARK: - Payloads

/// A payload that travels as a plist dictionary, converted through its
/// `Codable` form so the keys are the property names.
protocol WatchPayload: Codable, Sendable {}

extension WatchPayload {
    /// The payload's fields. A nil optional is left out, as the hand-built
    /// dictionaries did.
    var dictionary: [String: Any] {
        guard let data = try? PropertyListEncoder().encode(self),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        return dict
    }

    /// Reads the payload's fields out of a received dictionary, ignoring any
    /// other keys (`type` among them). Nil when a required field is missing or
    /// has the wrong type.
    init?(dictionary: [String: Any]) {
        guard PropertyListSerialization.propertyList(dictionary, isValidFor: .binary),
              let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0),
              let value = try? PropertyListDecoder().decode(Self.self, from: data) else { return nil }
        self = value
    }
}

/// Watch → iPhone: run the green detector for a course.
struct HoleDetectionRequest: WatchPayload, Equatable {
    let courseId: UUID
    /// Identifies the request: each one is a distinct context (an identical
    /// dictionary is not redelivered), and it is how the phone tells a new
    /// request from the same one arriving again. Optional on receipt only.
    let at: Double?
}

/// iPhone → Watch: progress on a requested analysis.
struct HoleDetectionStatusUpdate: WatchPayload, Equatable {
    let courseId: UUID
    let state: HoleDetectionPhoneState
    let at: Double?
}

/// iPhone → Watch: a round row the phone received from the server.
struct RoundRowRelay: WatchPayload, Equatable {
    let table: String
    let kind: String
    /// The row as JSON.
    let record: Data
}

/// iPhone → Watch: GPS test mode and where it puts the user.
struct TestModeState: WatchPayload, Equatable {
    let enabled: Bool
    let lat: Double?
    let lon: Double?

    init(enabled: Bool, lat: Double?, lon: Double?) {
        self.enabled = enabled
        self.lat = lat
        self.lon = lon
    }

    /// A missing `enabled` reads as off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lon = try c.decodeIfPresent(Double.self, forKey: .lon)
    }
}

/// A JSON-encoded value (hole detection data, filter settings, the auth
/// session) under `data`.
struct EncodedPayload: WatchPayload, Equatable {
    let data: Data
}

struct LoggerEnabledPayload: WatchPayload, Equatable {
    let value: Bool
}

struct WatchLogPayload: WatchPayload, Equatable {
    let msg: String
}

// MARK: - Messages

/// A `sendMessage` / `transferUserInfo` message.
enum WatchMessage {
    /// iPhone → Watch. JSON `CourseHoleDetectionData`.
    case holeDetectionData(Data)
    /// Either way. JSON `HoleDetectionFilterSettings`.
    case holeFilterSettings(Data)
    /// iPhone → Watch. JSON `AuthSession`; empty means signed out.
    case authSession(Data)
    /// Watch → iPhone: send the session again.
    case requestAuthSession
    /// iPhone → Watch.
    case clientEventLoggerEnabled(Bool)
    /// iPhone → Watch. UserDefaults keys and values to write as they are, so
    /// the keys are open-ended and the values any plist type; this one stays
    /// a dictionary.
    case devParam([String: Any])
    case holeDetectionRequest(HoleDetectionRequest)
    case holeDetectionStatus(HoleDetectionStatusUpdate)
    case roundRow(RoundRowRelay)
    case testModeState(TestModeState)
    /// Watch → iPhone console line.
    case watchLog(String)

    private enum Kind: String {
        case holeDetectionData, holeFilterSettings, authSession, requestAuthSession,
             clientEventLoggerEnabled, devParam, holeDetectionRequest, holeDetectionStatus,
             roundRow, testModeState, watchLog
    }

    /// Nil for an unknown `type` or a payload that does not read.
    init?(_ message: [String: Any]) {
        guard let raw = message["type"] as? String, let kind = Kind(rawValue: raw) else { return nil }
        switch kind {
        case .holeDetectionData:
            guard let p = EncodedPayload(dictionary: message) else { return nil }
            self = .holeDetectionData(p.data)
        case .holeFilterSettings:
            guard let p = EncodedPayload(dictionary: message) else { return nil }
            self = .holeFilterSettings(p.data)
        case .authSession:
            guard let p = EncodedPayload(dictionary: message) else { return nil }
            self = .authSession(p.data)
        case .requestAuthSession:
            self = .requestAuthSession
        case .clientEventLoggerEnabled:
            guard let p = LoggerEnabledPayload(dictionary: message) else { return nil }
            self = .clientEventLoggerEnabled(p.value)
        case .devParam:
            self = .devParam(message.filter { $0.key != "type" })
        case .holeDetectionRequest:
            guard let p = HoleDetectionRequest(dictionary: message) else { return nil }
            self = .holeDetectionRequest(p)
        case .holeDetectionStatus:
            guard let p = HoleDetectionStatusUpdate(dictionary: message) else { return nil }
            self = .holeDetectionStatus(p)
        case .roundRow:
            guard let p = RoundRowRelay(dictionary: message) else { return nil }
            self = .roundRow(p)
        case .testModeState:
            guard let p = TestModeState(dictionary: message) else { return nil }
            self = .testModeState(p)
        case .watchLog:
            guard let p = WatchLogPayload(dictionary: message) else { return nil }
            self = .watchLog(p.msg)
        }
    }

    /// The dictionary to send.
    var dictionary: [String: Any] {
        let kind: Kind
        var fields: [String: Any]
        switch self {
        case .holeDetectionData(let d): kind = .holeDetectionData; fields = EncodedPayload(data: d).dictionary
        case .holeFilterSettings(let d): kind = .holeFilterSettings; fields = EncodedPayload(data: d).dictionary
        case .authSession(let d): kind = .authSession; fields = EncodedPayload(data: d).dictionary
        case .requestAuthSession: kind = .requestAuthSession; fields = [:]
        case .clientEventLoggerEnabled(let v): kind = .clientEventLoggerEnabled; fields = LoggerEnabledPayload(value: v).dictionary
        case .devParam(let params): kind = .devParam; fields = params
        case .holeDetectionRequest(let p): kind = .holeDetectionRequest; fields = p.dictionary
        case .holeDetectionStatus(let p): kind = .holeDetectionStatus; fields = p.dictionary
        case .roundRow(let p): kind = .roundRow; fields = p.dictionary
        case .testModeState(let p): kind = .testModeState; fields = p.dictionary
        case .watchLog(let m): kind = .watchLog; fields = WatchLogPayload(msg: m).dictionary
        }
        fields["type"] = kind.rawValue
        return fields
    }
}

// MARK: - Application context

/// The application-context keys. A context holds every key its sender has
/// ever set, so each arrives many times (see `handleApplicationContext`).
enum WatchContextKey: String {
    /// iPhone → Watch. JSON `CourseHoleDetectionData`.
    case holeDetectionData
    /// Either way. JSON `HoleDetectionFilterSettings`.
    case holeFilterSettings
    /// iPhone → Watch. JSON `AuthSession`; empty means signed out.
    case authSession
    /// iPhone → Watch. Bool.
    case clientEventLoggerEnabled
    /// iPhone → Watch. Every dev parameter the phone has set, as UserDefaults
    /// keys and values.
    case devParams
    /// Watch → iPhone. `HoleDetectionRequest`.
    case holeDetectionRequest
    /// iPhone → Watch. `HoleDetectionStatusUpdate`.
    case holeDetectionStatus
    /// iPhone → Watch. `TestModeState`.
    case testModeState
    /// Watch → iPhone. The watch's `CFBundleVersion`.
    case watchBuild
}
