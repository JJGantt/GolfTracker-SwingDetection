import Foundation
import CoreLocation

/// Pure function returning whether a round should be auto-ended.
///
/// Two conditions, either ends the round:
///   - `lastActivityAt` more than 1h ago (no strokes added, no hole nav)
///   - User is >2km from every hole on the course (left the venue)
///
/// Compiled into both iOS and watchOS targets. The platform DataStores
/// each run a 60s timer that calls this and routes a positive result into
/// their respective `endRound`.
enum RoundLifecycleEvaluator {
    static let inactivityThreshold: TimeInterval = 60 * 60
    static let offCourseThresholdMeters: Double = 2_000

    struct Decision {
        let shouldEnd: Bool
        let reason: String?
        static let keep = Decision(shouldEnd: false, reason: nil)
    }

    static func evaluate(round: Round, location: CLLocationCoordinate2D?) -> Decision {
        if round.endedAt != nil { return .keep }

        // Inactivity sweep — pure wall-clock, no GPS required.
        if let last = round.lastActivityAt,
           Date().timeIntervalSince(last) > inactivityThreshold {
            return Decision(shouldEnd: true, reason: "inactive >1h")
        }

        // Off-course sweep — needs both a GPS fix AND at least one hole
        // with coordinates. If holes are still being placed (geometry mode
        // early in a round), holeLocs may be empty; skip in that case so a
        // user mid-placement isn't kicked.
        if let loc = location {
            let user = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            let holeLocs = round.holes.compactMap { h -> CLLocation? in
                guard let c = h.coordinate else { return nil }
                return CLLocation(latitude: c.latitude, longitude: c.longitude)
            }
            if !holeLocs.isEmpty {
                let minDist = holeLocs.map { $0.distance(from: user) }.min() ?? 0
                if minDist > offCourseThresholdMeters {
                    return Decision(
                        shouldEnd: true,
                        reason: "off course (\(Int(minDist))m from nearest hole)"
                    )
                }
            }
        }

        return .keep
    }

    /// True when `reason` is the inactivity decision — the one decision
    /// that must be server-verified before acting (see below).
    static func isInactivityReason(_ reason: String?) -> Bool {
        reason?.hasPrefix("inactive") == true
    }

    /// Fetch the round's `last_activity_at` from Supabase. The local copy
    /// can be arbitrarily stale when the OTHER device was the writer while
    /// this one was backgrounded — Realtime doesn't replay missed events,
    /// and the sweep fires immediately on foreground. The May 31 Wekiva
    /// round was wrongly auto-ended exactly this way: the phone woke with
    /// hole-1-era state and killed a round the watch had been writing to
    /// all along. Returns nil when offline / on any error; callers fall
    /// back to the local value in that case.
    static func serverLastActivityAt(roundId: UUID) async -> Date? {
        struct Row: Decodable { let last_activity_at: String? }
        guard let rows: [Row] = try? await SupabaseManager.shared
            .from("rounds")
            .select("last_activity_at")
            .eq("id", value: roundId.uuidString)
            .limit(1)
            .execute()
            .value,
            let raw = rows.first?.last_activity_at else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
    }
}
