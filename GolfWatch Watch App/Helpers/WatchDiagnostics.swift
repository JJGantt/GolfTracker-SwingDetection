import Foundation

/// Cheap-per-call counters that flush a single batched event to
/// ClientEventLogger once per second. The point is to instrument hot
/// per-frame paths (SwiftUI body re-evals, crown ticks) without
/// reproducing the per-call HTTPS-POST lag we just removed.
///
/// Per-call cost: one Int increment under a serial DispatchQueue (no
/// allocations, no network). Flush cost: one `ClientEventLogger.log`
/// per second per active counter.
final class WatchDiagnostics {
    static let shared = WatchDiagnostics()

    private let queue = DispatchQueue(label: "WatchDiagnostics", qos: .utility)
    private var bodyEvals: Int = 0
    private var crownTicks: Int = 0
    private var clubIntegerChanges: Int = 0
    private var timer: DispatchSourceTimer?

    private init() {
        startTimer()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        self.timer = t
    }

    func recordBodyEval() {
        guard ClientEventLogger.enabled else { return }
        queue.async { self.bodyEvals += 1 }
    }

    func recordCrownTick() {
        guard ClientEventLogger.enabled else { return }
        queue.async { self.crownTicks += 1 }
    }

    func recordClubIntegerChange() {
        guard ClientEventLogger.enabled else { return }
        queue.async { self.clubIntegerChanges += 1 }
    }

    private func flush() {
        // Only emit a row when something happened in the past second —
        // skips silent ticks so the log isn't 86,400 rows/day of zeros.
        guard bodyEvals > 0 || crownTicks > 0 || clubIntegerChanges > 0 else { return }
        let body = bodyEvals
        let ticks = crownTicks
        let changes = clubIntegerChanges
        bodyEvals = 0
        crownTicks = 0
        clubIntegerChanges = 0

        // Probe main-actor latency: schedule a block on main, measure how
        // long until it actually runs. Idle main = sub-millisecond. Backed
        // up main = 50ms+. This is the most direct measure of why the OS
        // would throttle crown event delivery to us.
        let probeStart = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async {
            let probeEnd = DispatchTime.now().uptimeNanoseconds
            let mainLatencyMs = Int((probeEnd - probeStart) / 1_000_000)
            ClientEventLogger.log("watch.diagnostics.tick", level: .diagnostic, detail: [
                "bodyEvals": .integer(body),
                "crownTicks": .integer(ticks),
                "clubIntegerChanges": .integer(changes),
                "mainLatencyMs": .integer(mainLatencyMs)
            ])
        }
    }
}
