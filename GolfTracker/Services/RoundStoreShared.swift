import Foundation
import CoreLocation

/// The scorecard choice the resolver is waiting on, when GolfCourseAPI
/// returned more than one plausible course.
struct PendingScorecardPicker: Identifiable {
    var id = UUID()
    let originalName: String
    let candidates: [RoundResolver.ScorecardCandidate]
}

/// What the phone's `DataStore` and the watch's `WatchDataStore` do the same
/// way: starting a round from where the user stands (resolving the course and
/// asking the user to pick when it is ambiguous), the green candidates the
/// map and the green-placement picker offer, club lookups, and the sweep that
/// ends an abandoned round. Each store keeps its own state; the behaviour is
/// written once, here.
protocol RoundStoreShared: AnyObject {
    var availableClubs: [ClubData] { get }
    var clubTypes: [ClubTypeData] { get }
    var holeFilterSettings: HoleDetectionFilterSettings { get }
    var holeDetectionDataByCourse: [UUID: CourseHoleDetectionData] { get }
    func osmCourseData(forCourseId id: UUID) -> OSMCourseData?

    var currentRound: Round? { get }
    var lifecycleTimer: Timer? { get set }
    /// Ends `round` because the lifecycle sweep said so.
    func endRoundForLifecycle(_ round: Round, reason: String)
    /// The server says `round` saw activity at `date`, later than this device knew.
    func adoptServerActivity(_ date: Date, for round: Round)

    var roundStartStatus: String? { get set }
    var pendingCoursePicker: [RoundResolver.CourseCandidate]? { get set }
    var pendingCoursePickerCompletion: ((RoundResolver.CourseCandidate?) -> Void)? { get set }
    var pendingScorecardPicker: PendingScorecardPicker? { get set }
    var pendingScorecardPickerCompletion: ((GCAPICourse?) -> Void)? { get set }
    var pendingCourseNamePrompt: Bool { get set }
    var pendingCourseNameCompletion: ((String?) -> Void)? { get set }
    /// The resolver found the course; start the round there.
    func handleResolved(_ resolution: RoundResolver.Resolution)
    /// No GPS fix at all: start a round at a course the user names.
    func startManualQuickRound()
    /// Brings the store's view of the current round up to date after the
    /// catch-up read that precedes a round start.
    func refreshAfterReconcile()
    /// Whether a round start with no fix yet asks for location permission.
    var requestsLocationOnRoundStart: Bool { get }
}

extension RoundStoreShared {

    // MARK: - Clubs

    func getClub(byId id: UUID) -> ClubData? {
        availableClubs.first { $0.id == id }
    }

    func getClubType(byId id: UUID) -> ClubTypeData? {
        clubTypes.first { $0.id == id }
    }

    func getTypeName(for club: ClubData) -> String {
        clubTypes.first { $0.id == club.clubTypeId }?.name ?? club.name
    }

    // MARK: - Green candidates

    /// The greens to draw and to offer when placing a hole: the course's OSM
    /// green polygons (always offered), then the blob detector's candidates
    /// that pass the user's filter settings.
    func filteredGreenCandidates(for courseId: UUID?) -> [HoleDetectionBlob] {
        guard let courseId else { return [] }
        return GreenCandidates.list(osmGreens: osmCourseData(forCourseId: courseId)?.greens.map(\.points),
                                    detection: holeDetectionDataByCourse[courseId],
                                    filter: holeFilterSettings)
    }

    // MARK: - Round lifecycle

    /// Evaluates the current round every 60 s, and once now so a stale round
    /// found at launch ends without waiting a minute. The minute is a clock
    /// arrival: an hour of inactivity changes nothing anyone could be told.
    func startRoundLifecycleSweep() {
        lifecycleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateRoundLifecycle()
        }
        RunLoop.main.add(timer, forMode: .common)
        lifecycleTimer = timer
        evaluateRoundLifecycle()
    }

    func evaluateRoundLifecycle() {
        guard let round = currentRound else { return }
        // Test mode: pass nil location so the off-course check is skipped.
        // Simulated GPS is nowhere near the round's real holes and would
        // auto-end every test round. Inactivity still applies.
        let location = LocationManager.shared.isTestModeEnabled
            ? nil
            : LocationManager.shared.location?.coordinate
        let decision = RoundLifecycleEvaluator.evaluate(round: round, location: location)
        guard decision.shouldEnd else { return }
        if RoundLifecycleEvaluator.isInactivityReason(decision.reason) {
            // This device's lastActivityAt may be stale (the other device was
            // the writer while this one was backgrounded, or the watch had no
            // Realtime during a solo round), so ask the server before ending.
            // Offline: trust the local value.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let fresh = await RoundLifecycleEvaluator.serverLastActivityAt(roundId: round.id),
                   Date().timeIntervalSince(fresh) <= RoundLifecycleEvaluator.inactivityThreshold {
                    self.adoptServerActivity(fresh, for: round)
                    return
                }
                self.endRoundForLifecycle(round, reason: decision.reason ?? "lifecycle")
            }
        } else {
            endRoundForLifecycle(round, reason: decision.reason ?? "lifecycle")
        }
    }

    // MARK: - Starting a round where the user stands

    func startRoundAtCurrentLocation() {
        // Catch up with the server before creating anything. Starting a round
        // auto-ends any prior one, so starting while the other device's round
        // exists but hasn't synced yet would make TWO live rounds: both upsert,
        // `currentRound` on each device picks the most recent by date, and the
        // two can disagree about which round is being played.
        Task { @MainActor in
            await RealtimeSync.shared.reconcileRoundsWithSupabase()
            refreshAfterReconcile()
            guard currentRound == nil else {
                // Say so. Aborting silently makes Start Round look broken.
                ClientEventLogger.log("round.start.abortedExistingRound")
                roundStartStatus = "Round already in progress"
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.roundStartStatus == "Round already in progress" {
                        self?.roundStartStatus = nil
                    }
                }
                return
            }
            beginRoundResolution()
        }
    }

    func pickCourseCandidate(_ candidate: RoundResolver.CourseCandidate?) {
        let completion = pendingCoursePickerCompletion
        pendingCoursePicker = nil
        pendingCoursePickerCompletion = nil
        completion?(candidate)
    }

    func pickScorecardCandidate(_ course: GCAPICourse?) {
        let completion = pendingScorecardPickerCompletion
        pendingScorecardPicker = nil
        pendingScorecardPickerCompletion = nil
        completion?(course)
    }

    /// Answer the name-this-course prompt. Nil or blank cancels the round.
    func submitCourseName(_ name: String?) {
        let completion = pendingCourseNameCompletion
        pendingCourseNamePrompt = false
        pendingCourseNameCompletion = nil
        completion?(name)
    }

    private func beginRoundResolution() {
        guard let coordinate = LocationManager.shared.location?.coordinate else {
            // No fix YET is not no fix. Dropping straight to the manual path
            // prompts for a course name, which reads as "which course are you
            // at?": the user types the right name and gets a brand-new course
            // with no OSM data, holes or centroid, while the real course sits
            // in the table unused.
            roundStartStatus = "Waiting for GPS…"
            if requestsLocationOnRoundStart { LocationManager.shared.requestPermission() }
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(RoundStart.locationWaitSeconds)
                while Date() < deadline {
                    if LocationManager.shared.location != nil { break }
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
                guard let coordinate = LocationManager.shared.location?.coordinate else {
                    ClientEventLogger.log("round.start.noGPSAfterWait")
                    roundStartStatus = nil
                    startManualQuickRound()
                    return
                }
                resolveRound(at: coordinate)
            }
            return
        }
        resolveRound(at: coordinate)
    }

    private func resolveRound(at coordinate: CLLocationCoordinate2D) {
        roundStartStatus = "Locating…"
        RoundResolver.shared.resolve(
            at: coordinate,
            progress: { [weak self] step in
                DispatchQueue.main.async { self?.roundStartStatus = RoundStart.status(for: step) }
            },
            coursePicker: { [weak self] candidates, choose in
                DispatchQueue.main.async {
                    self?.pendingCoursePicker = candidates
                    self?.pendingCoursePickerCompletion = choose
                }
            },
            scorecardPicker: { [weak self] originalName, ranked, choose in
                DispatchQueue.main.async {
                    self?.pendingScorecardPicker = PendingScorecardPicker(originalName: originalName, candidates: ranked)
                    self?.pendingScorecardPickerCompletion = choose
                }
            },
            courseNamePrompt: { [weak self] complete in
                DispatchQueue.main.async {
                    self?.pendingCourseNameCompletion = complete
                    self?.pendingCourseNamePrompt = true
                }
            },
            completion: { [weak self] resolution in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.roundStartStatus = nil
                    // Nil means the user backed out (cancelled the course
                    // picker or the name prompt): start nothing.
                    if let resolution {
                        self.handleResolved(resolution)
                    }
                }
            }
        )
    }
}

enum RoundStart {
    /// How long a round start with no GPS fix waits for one before falling
    /// back to a course the user names.
    static let locationWaitSeconds: TimeInterval = 12

    static func status(for step: RoundResolver.Step) -> String? {
        switch step {
        case .locating: return "Locating…"
        case .searchingShared: return "Checking nearby courses…"
        case .searchingPOIs: return "Searching nearby courses…"
        case .picking: return "Pick a course"
        case .loadingCourseData(let name): return "\(name) — loading…"
        case .ready: return nil
        case .failed(let msg): return msg
        }
    }
}
