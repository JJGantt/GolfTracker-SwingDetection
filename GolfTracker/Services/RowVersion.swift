import Foundation

/// Which copy of a synced row is newer. A row's version is its `updated_at`,
/// which the server stamps on every write (migration 00054), as whole
/// microseconds since 1970 — Postgres keeps microseconds, and `Date` would
/// round two writes in the same millisecond together.
///
/// `RealtimeSync` stores the version it last applied on the row
/// (`serverVersion`) and drops an incoming copy that is older: rows reach the
/// watch through the phone, and a copy queued by `transferUserInfo` while the
/// watch was out of reach can arrive after a newer one.
enum RowVersion {

    /// Whether `incoming` is older than what was already applied. A row
    /// without a version on either side is never stale.
    static func isStale(incoming: Int64?, applied: Int64?) -> Bool {
        guard let incoming, let applied else { return false }
        return incoming < applied
    }

    /// Microseconds since 1970 for a Postgres `timestamptz` as JSON carries it:
    /// `2026-11-01T14:03:09.12345+00:00`, with `T` or a space, 0-6 fractional
    /// digits, and `Z`, `±HH`, `±HHMM` or `±HH:MM`. Nil for anything else.
    static func parse(_ text: String) -> Int64? {
        let c = Array(text.utf8)
        var i = 0
        func digits(_ n: Int) -> Int64? {
            guard i + n <= c.count else { return nil }
            var v: Int64 = 0
            for k in i..<(i + n) {
                guard c[k] >= 48, c[k] <= 57 else { return nil }
                v = v * 10 + Int64(c[k] - 48)
            }
            i += n
            return v
        }
        func expect(_ chars: String) -> Bool {
            guard i < c.count, chars.utf8.contains(c[i]) else { return false }
            i += 1
            return true
        }
        guard let year = digits(4), expect("-"), let month = digits(2), expect("-"), let day = digits(2),
              expect("T "), let hour = digits(2), expect(":"), let minute = digits(2), expect(":"),
              let second = digits(2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var micros: Int64 = 0
        if i < c.count, c[i] == UInt8(ascii: ".") {
            i += 1
            var n = 0
            while i < c.count, c[i] >= 48, c[i] <= 57 {
                if n < 6 { micros = micros * 10 + Int64(c[i] - 48) }
                n += 1; i += 1
            }
            guard n > 0 else { return nil }
            for _ in min(n, 6)..<6 { micros *= 10 }
        }
        var offsetSeconds: Int64 = 0
        if i < c.count, c[i] == UInt8(ascii: "Z") {
            i += 1
        } else if i < c.count, c[i] == UInt8(ascii: "+") || c[i] == UInt8(ascii: "-") {
            let sign: Int64 = c[i] == UInt8(ascii: "-") ? -1 : 1
            i += 1
            guard let oh = digits(2) else { return nil }
            var om: Int64 = 0
            if i < c.count {
                _ = expect(":")
                guard let m = digits(2) else { return nil }
                om = m
            }
            offsetSeconds = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == c.count else { return nil }
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second - offsetSeconds
        return seconds * 1_000_000 + micros
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
    /// `days_from_civil`).
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
