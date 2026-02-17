import Foundation
import CoreLocation
import MapKit

class DataStore: ObservableObject {
    @Published var courses: [Course] = []
    @Published var rounds: [Round] = []
    @Published var clubTypes: [ClubTypeData] = []
    @Published var availableClubs: [ClubData] = []
    @Published var clubSets: [ClubSet] = []
    @Published var errorMessage: String?
    @Published var holeDetectionDataByCourse: [UUID: CourseHoleDetectionData] = [:]
    @Published var holeDetectionRunStateByCourse: [UUID: HoleDetectionRunState] = [:]
    @Published var holeFilterSettings: HoleDetectionFilterSettings = .default

    private let coursesFileName = "courses.json"
    private let roundsFileName = "rounds.json"
    private let clubTypesFileName = "clubTypes.json"
    private let clubsFileName = "clubs.json"
    private let clubSetsFileName = "clubSets.json"
    private let holeDetectionFileName = "holeDetectionData.json"
    private let holeFilterSettingsKey = "holeFilterSettings"
    private let holeDetectionAnalyzer = HoleDetectionAnalyzer()
    private let holeDetectionTestCenter = CLLocationCoordinate2D(
        latitude: 30.285357365597697,
        longitude: -81.74623642434663
    )

    init() {
        print("🏌️ DataStore initialized!")
        loadCourses()
        loadRounds()
        loadClubTypes()
        loadClubs()
        loadClubSets()
        loadHoleDetectionData()
        loadHoleFilterSettings()
        print("🏌️ DataStore loaded \(courses.count) courses, \(rounds.count) rounds, \(clubTypes.count) club types, \(availableClubs.count) clubs, and \(clubSets.count) club sets")

        // Initialize with default club types if needed
        if clubTypes.isEmpty {
            clubTypes = ClubTypeData.defaultClubTypes()
            saveClubTypes()
            print("🏌️ Initialized with \(clubTypes.count) default club types")
        }

        // Initialize with default clubs if needed
        if availableClubs.isEmpty {
            // Create default clubs using the club type IDs
            for clubType in clubTypes {
                let club = ClubData(name: "Default", clubTypeId: clubType.id, isDefault: true)
                availableClubs.append(club)
            }
            saveClubs()
            print("🏌️ Initialized with \(availableClubs.count) default clubs")
        }

        // Create default club set if no sets exist
        if clubSets.isEmpty && !clubTypes.isEmpty {
            // Create type selections with default clubs
            let typeSelections = clubTypes.map { clubType -> TypeSelection in
                let defaultClub = availableClubs.first(where: { $0.clubTypeId == clubType.id })
                return TypeSelection(typeId: clubType.id, activeClubId: defaultClub?.id)
            }
            let defaultSet = ClubSet(
                name: "Default Set",
                typeSelections: typeSelections,
                isActive: true
            )
            clubSets.append(defaultSet)
            saveClubSets()
        }

        // Set up Watch Connectivity callbacks
        setupWatchConnectivity()
    }

    private func setupWatchConnectivity() {
        WatchConnectivityManager.shared.onReceiveStrokes = { [weak self] strokes in
            print("📱 [DataStore] Received \(strokes.count) strokes from Watch")
            self?.mergeStrokesFromWatch(strokes)
        }

        WatchConnectivityManager.shared.onReceiveRound = { [weak self] round in
            print("📱 [DataStore] Received round update from Watch: \(round.courseName)")
            self?.updateRoundFromWatch(round)
        }

        WatchConnectivityManager.shared.onReceiveHoleFilterSettings = { [weak self] settings in
            print("📱 [DataStore] Received hole filter settings from Watch")
            DispatchQueue.main.async {
                self?.holeFilterSettings = settings
                self?.saveHoleFilterSettings()
            }
        }

        // Send active set clubs and their types to Watch on startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            let activeClubs = self.getClubsInActiveSet()
            print("📱 [DataStore] Sending \(activeClubs.count) active clubs to Watch on startup")
            WatchConnectivityManager.shared.sendClubs(activeClubs)
            print("📱 [DataStore] Sending \(self.clubTypes.count) club types to Watch on startup")
            WatchConnectivityManager.shared.sendClubTypes(self.clubTypes)
        }
    }

    private func mergeStrokesFromWatch(_ strokes: [Stroke]) {
        // Find the active round and add the strokes
        guard let activeRoundIndex = rounds.firstIndex(where: { round in
            // The most recent round is likely the active one
            round.date == rounds.max(by: { $0.date < $1.date })?.date
        }) else {
            print("📱 [DataStore] ERROR: No active round found to add strokes to")
            return
        }

        print("📱 [DataStore] Adding strokes to round: \(rounds[activeRoundIndex].courseName)")

        for stroke in strokes {
            // Check if stroke already exists (avoid duplicates)
            let strokeExists = rounds[activeRoundIndex].strokes.contains(where: { $0.id == stroke.id })
            if !strokeExists {
                rounds[activeRoundIndex].strokes.append(stroke)
                print("📱 [DataStore] Added stroke \(stroke.strokeNumber) on hole \(stroke.holeNumber)")
            } else {
                print("📱 [DataStore] Stroke already exists, skipping")
            }
        }

        saveRounds()
        print("📱 [DataStore] Saved round with \(rounds[activeRoundIndex].strokes.count) total strokes")
    }

    private func updateRoundFromWatch(_ watchRound: Round) {
        // Find the round by ID
        guard let roundIndex = rounds.firstIndex(where: { $0.id == watchRound.id }) else {
            print("📱 [DataStore] ERROR: Round not found for update")
            return
        }

        // Detect new holes before updating
        let oldHoles = rounds[roundIndex].holes
        let newHoles = watchRound.holes.filter { newHole in
            !oldHoles.contains(where: { $0.number == newHole.number })
        }

        // Update everything from Watch
        rounds[roundIndex].holes = watchRound.holes
        rounds[roundIndex].completedHoles = watchRound.completedHoles
        rounds[roundIndex].currentHoleIndex = watchRound.currentHoleIndex
        rounds[roundIndex].targets = watchRound.targets
        rounds[roundIndex].strokes = watchRound.strokes
        rounds[roundIndex].holeDetectionEnabled = watchRound.holeDetectionEnabled
        rounds[roundIndex].locationTestModeEnabled = watchRound.locationTestModeEnabled

        // Also update the course with the new holes
        if let courseIndex = courses.firstIndex(where: { $0.id == watchRound.courseId }) {
            courses[courseIndex].holes = watchRound.holes
            saveCourses()
        }

        saveRounds()
        print("📱 [DataStore] Updated round from Watch: \(watchRound.strokes.count) strokes, \(watchRound.completedHoles.count) holes completed, current hole index: \(watchRound.currentHoleIndex)")

        // Handle satellite imagery for new holes
        if !newHoles.isEmpty {
            let watchMsg = "⌚ Detected \(newHoles.count) new hole(s) from Watch sync"
            print(watchMsg)
            SatelliteLogHandler.shared.log(watchMsg)
            for hole in newHoles {
                handleNewHoleAdded(courseId: watchRound.courseId, hole: hole)
            }
        }
    }

    private var coursesFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(coursesFileName)
    }

    private var roundsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(roundsFileName)
    }

    private var clubTypesFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(clubTypesFileName)
    }

    private var clubsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(clubsFileName)
    }

    private var clubSetsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(clubSetsFileName)
    }

    private var holeDetectionFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(holeDetectionFileName)
    }
    
    func loadCourses() {
        guard FileManager.default.fileExists(atPath: coursesFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: coursesFileURL)
            courses = try JSONDecoder().decode([Course].self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load courses: \(error.localizedDescription)"
        }
    }

    func loadRounds() {
        guard FileManager.default.fileExists(atPath: roundsFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: roundsFileURL)
            rounds = try JSONDecoder().decode([Round].self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load rounds: \(error.localizedDescription)"
        }
    }

    func saveCourses() {
        do {
            let data = try JSONEncoder().encode(courses)
            try data.write(to: coursesFileURL)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save courses: \(error.localizedDescription)"
        }
    }

    func saveRounds() {
        do {
            let data = try JSONEncoder().encode(rounds)
            try data.write(to: roundsFileURL)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save rounds: \(error.localizedDescription)"
        }
    }

    func loadClubTypes() {
        guard FileManager.default.fileExists(atPath: clubTypesFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: clubTypesFileURL)
            clubTypes = try JSONDecoder().decode([ClubTypeData].self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load club types: \(error.localizedDescription)"
        }
    }

    func saveClubTypes() {
        do {
            let data = try JSONEncoder().encode(clubTypes)
            try data.write(to: clubTypesFileURL)
            errorMessage = nil
            // Sync club types to Watch
            WatchConnectivityManager.shared.sendClubTypes(clubTypes)
        } catch {
            errorMessage = "Failed to save club types: \(error.localizedDescription)"
        }
    }

    func loadClubs() {
        guard FileManager.default.fileExists(atPath: clubsFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: clubsFileURL)
            availableClubs = try JSONDecoder().decode([ClubData].self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load clubs: \(error.localizedDescription)"
        }
    }

    func loadClubSets() {
        guard FileManager.default.fileExists(atPath: clubSetsFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: clubSetsFileURL)
            clubSets = try JSONDecoder().decode([ClubSet].self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load club sets: \(error.localizedDescription)"
        }
    }

    func saveClubs() {
        do {
            let data = try JSONEncoder().encode(availableClubs)
            try data.write(to: clubsFileURL)
            errorMessage = nil
            // Sync active set clubs to Watch
            syncActiveClubsToWatch()
        } catch {
            errorMessage = "Failed to save clubs: \(error.localizedDescription)"
        }
    }

    /// Syncs only the clubs in the active set to the Watch
    func syncActiveClubsToWatch() {
        let activeClubs = getClubsInActiveSet()
        print("📱 [DataStore] Syncing \(activeClubs.count) active clubs to Watch")
        WatchConnectivityManager.shared.sendClubs(activeClubs)
        WatchConnectivityManager.shared.sendClubTypes(clubTypes)
    }

    func saveClubSets() {
        do {
            let data = try JSONEncoder().encode(clubSets)
            try data.write(to: clubSetsFileURL)
            errorMessage = nil
            // Sync active set clubs to Watch when club sets change
            syncActiveClubsToWatch()
        } catch {
            errorMessage = "Failed to save club sets: \(error.localizedDescription)"
        }
    }

    func loadHoleDetectionData() {
        guard FileManager.default.fileExists(atPath: holeDetectionFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: holeDetectionFileURL)
            let detections = try JSONDecoder().decode([CourseHoleDetectionData].self, from: data)
            holeDetectionDataByCourse = Dictionary(uniqueKeysWithValues: detections.map { ($0.courseId, $0) })
        } catch {
            print("📱 [DataStore] Failed to load hole detection data: \(error.localizedDescription)")
        }
    }

    func saveHoleDetectionData() {
        do {
            let detections = Array(holeDetectionDataByCourse.values)
            let data = try JSONEncoder().encode(detections)
            try data.write(to: holeDetectionFileURL)
        } catch {
            print("📱 [DataStore] Failed to save hole detection data: \(error.localizedDescription)")
        }
    }

    func loadHoleFilterSettings() {
        guard let data = UserDefaults.standard.data(forKey: holeFilterSettingsKey),
              let settings = try? JSONDecoder().decode(HoleDetectionFilterSettings.self, from: data) else {
            holeFilterSettings = .default
            return
        }
        holeFilterSettings = settings
    }

    func saveHoleFilterSettings() {
        guard let data = try? JSONEncoder().encode(holeFilterSettings) else { return }
        UserDefaults.standard.set(data, forKey: holeFilterSettingsKey)
    }

    func holeDetectionStatus(for courseId: UUID) -> HoleDetectionRunState? {
        holeDetectionRunStateByCourse[courseId]
    }

    func filteredHoleDetectionBlobs(for courseId: UUID) -> [HoleDetectionBlob] {
        guard let data = holeDetectionDataByCourse[courseId] else { return [] }
        return data.blobs.filter { $0.passesFilter(holeFilterSettings) }
    }
    
    func addCourse(name: String) {
        let course = Course(name: name, holes: [])
        courses.append(course)
        saveCourses()
    }

    func deleteCourse(_ course: Course) {
        courses.removeAll { $0.id == course.id }
        saveCourses()
    }

    func updateCourseInfo(_ course: Course, name: String, rating: Double?, slope: Int?) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[index].name = name
        courses[index].rating = rating
        courses[index].slope = slope
        saveCourses()
    }

    func updateCourseCity(_ course: Course) {
        guard courses.firstIndex(where: { $0.id == course.id }) != nil,
              let coordinate = course.coordinate else { return }

        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self = self,
                  let placemark = placemarks?.first,
                  let city = placemark.locality else { return }

            DispatchQueue.main.async {
                if let currentIndex = self.courses.firstIndex(where: { $0.id == course.id }) {
                    self.courses[currentIndex].city = city
                    self.saveCourses()
                }
            }
        }
    }

    func addHole(to course: Course, coordinate: CLLocationCoordinate2D, par: Int? = nil, userLocation: CLLocationCoordinate2D? = nil) {
        guard let index = courses.firstIndex(where: { $0.id == course.id }) else { return }
        let holeNumber = courses[index].holes.count + 1
        let hole = Hole(number: holeNumber, coordinate: coordinate, par: par)
        courses[index].holes.append(hole)
        saveCourses()

        print("📱 [DataStore] Added hole #\(holeNumber) to course \(course.name)")

        // Handle satellite imagery for new hole (crop and transfer to Watch)
        handleNewHoleAdded(courseId: course.id, hole: hole, userLocation: userLocation)

        // Update city if this is the first hole or if city is not set
        if courses[index].city == nil {
            updateCourseCity(courses[index])
        }

        // Update active round with new hole data and resync to Watch
        updateActiveRoundHoles(for: course)
    }

    private func updateActiveRoundHoles(for course: Course) {
        // Find the most recent active round for this course
        guard let roundIndex = rounds.firstIndex(where: { round in
            round.courseId == course.id && round.date == rounds.max(by: { $0.date < $1.date })?.date
        }) else { return }

        // Update the round's holes with the latest from the course
        if let courseIndex = courses.firstIndex(where: { $0.id == course.id }) {
            let oldHoleCount = rounds[roundIndex].holes.count
            rounds[roundIndex].holes = courses[courseIndex].holes

            // If a new hole was added, update the current hole index to point to it
            if courses[courseIndex].holes.count > oldHoleCount {
                rounds[roundIndex].currentHoleIndex = courses[courseIndex].holes.count - 1
                print("📱 [DataStore] New hole added, updated currentHoleIndex to \(rounds[roundIndex].currentHoleIndex)")
            }

            saveRounds()

            // Resync to Watch
            print("📱 [DataStore] Updated active round holes, resyncing to Watch")
            WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
        }
    }

    func deleteHole(_ hole: Hole, from course: Course) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }) else { return }
        courses[courseIndex].holes.removeAll { $0.id == hole.id }
        // Renumber remaining holes
        for i in courses[courseIndex].holes.indices {
            courses[courseIndex].holes[i].number = i + 1
        }
        saveCourses()
        updateActiveRoundHoles(for: course)
    }

    func updateHole(_ hole: Hole, in course: Course, newCoordinate: CLLocationCoordinate2D, par: Int? = nil) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              let holeIndex = courses[courseIndex].holes.firstIndex(where: { $0.id == hole.id }) else { return }
        courses[courseIndex].holes[holeIndex].latitude = newCoordinate.latitude
        courses[courseIndex].holes[holeIndex].longitude = newCoordinate.longitude
        if let par = par {
            courses[courseIndex].holes[holeIndex].par = par
        }
        saveCourses()
        updateActiveRoundHoles(for: course)
    }

    func renumberHole(_ hole: Hole, in course: Course, newNumber: Int) {
        guard let courseIndex = courses.firstIndex(where: { $0.id == course.id }),
              let holeIndex = courses[courseIndex].holes.firstIndex(where: { $0.id == hole.id }) else { return }

        // Ensure new number is valid
        let clampedNumber = max(1, min(newNumber, courses[courseIndex].holes.count))

        // Remove hole from current position
        let removedHole = courses[courseIndex].holes.remove(at: holeIndex)

        // Insert at new position (newNumber - 1 because array is 0-indexed)
        let newIndex = clampedNumber - 1
        courses[courseIndex].holes.insert(removedHole, at: newIndex)

        // Renumber all holes sequentially
        for i in courses[courseIndex].holes.indices {
            courses[courseIndex].holes[i].number = i + 1
        }

        saveCourses()
        updateActiveRoundHoles(for: course)
    }


    // MARK: - Round Management

    func startRound(
        for course: Course,
        runHoleDetection: Bool = true,
        useHoleDetectionTestCoordinates: Bool = false
    ) -> Round {
        print("📱 [DataStore] startRound called for course: \(course.name)")
        let round = Round(
            courseId: course.id,
            courseName: course.name,
            holes: course.holes,
            holeDetectionEnabled: runHoleDetection,
            locationTestModeEnabled: useHoleDetectionTestCoordinates
        )
        rounds.append(round)
        saveRounds()

        // Start satellite log for this round
        SatelliteLogHandler.shared.startNewLog(roundId: round.id, courseName: course.name)

        print("📱 [DataStore] About to send round to Watch, holes: \(round.holes.count)")
        // Send active set clubs and club types first to ensure Watch has them before the round
        syncActiveClubsToWatch()
        // Send round to Watch
        WatchConnectivityManager.shared.sendRound(round)

        // Handle satellite imagery (async)
        handleSatelliteImagesForRound(course: course)

        if runHoleDetection {
            startHoleDetection(
                for: course,
                overrideCenter: useHoleDetectionTestCoordinates ? holeDetectionTestCenter : nil,
                allowCache: !useHoleDetectionTestCoordinates,
                persistResult: !useHoleDetectionTestCoordinates
            )
        }

        return round
    }

    private func startHoleDetection(
        for course: Course,
        overrideCenter: CLLocationCoordinate2D? = nil,
        allowCache: Bool = true,
        persistResult: Bool = true
    ) {
        if holeDetectionRunStateByCourse[course.id]?.isRunning == true {
            return
        }

        if allowCache, let cached = holeDetectionDataByCourse[course.id] {
            print("📱 [DataStore] Using cached hole detection data (\(cached.blobs.count) blobs)")
            holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                isRunning: false,
                message: "Hole detection ready",
                progress: 1.0,
                error: nil
            )
            WatchConnectivityManager.shared.sendHoleDetectionData(cached)
            return
        }

        guard let center = overrideCenter
                ?? calculateCourseCentroid(course: course)
                ?? LocationManager.shared.getCurrentLocation()?.coordinate
                ?? course.holes.first?.coordinate else {
            holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                isRunning: false,
                message: "Hole detection unavailable",
                progress: 0,
                error: "No location available"
            )
            return
        }

        let coverageRadius = holeDetectionCoverageRadius(for: course, center: center)
        holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
            isRunning: true,
            message: "Starting hole detection...",
            progress: 0,
            error: nil
        )

        holeDetectionAnalyzer.detect(
            courseId: course.id,
            center: center,
            coverageRadiusMeters: coverageRadius,
            progress: { [weak self] message, progress in
                DispatchQueue.main.async {
                    self?.holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                        isRunning: true,
                        message: message,
                        progress: progress,
                        error: nil
                    )
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let output):
                        let detectionData = output.data
                        print("📱 [DataStore] Hole detection diagnostics: tiles=\(output.diagnostics.tileCount), greenPx=\(output.diagnostics.totalGreenPixels), greenishPx=\(output.diagnostics.totalGreenishPixels), swappedExactPx=\(output.diagnostics.totalSwappedChannelExactPixels), preMergeBlobs=\(output.diagnostics.preMergeBlobCount), mergedBlobs=\(output.diagnostics.mergedBlobCount)")
                        if output.diagnostics.topGreenishColors.isEmpty {
                            print("📱 [DataStore] Hole detection top green-ish RGBs: none above threshold")
                        } else {
                            let colors = output.diagnostics.topGreenishColors.map(\.formatted).joined(separator: " | ")
                            print("📱 [DataStore] Hole detection top green-ish RGBs: \(colors)")
                        }
                        // Keep detection results in memory for current-round UI even when test runs are non-persistent.
                        self.holeDetectionDataByCourse[course.id] = detectionData
                        if persistResult {
                            self.saveHoleDetectionData()
                        }
                        self.holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                            isRunning: false,
                            message: output.diagnostics.summaryMessage,
                            progress: 1.0,
                            error: nil
                        )
                        WatchConnectivityManager.shared.sendHoleDetectionData(detectionData)
                    case .failure(let error):
                        self.holeDetectionRunStateByCourse[course.id] = HoleDetectionRunState(
                            isRunning: false,
                            message: "Hole detection failed",
                            progress: 0,
                            error: error.localizedDescription
                        )
                    }
                }
            }
        )
    }

    private func holeDetectionCoverageRadius(for course: Course, center: CLLocationCoordinate2D) -> Double {
        let coords = course.holes.compactMap { $0.coordinate }
        guard !coords.isEmpty else {
            return 2800
        }

        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let maxDistance = coords.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: centerLocation)
        }.max() ?? 0

        return max(1800, maxDistance + 800)
    }

    private func handleSatelliteImagesForRound(course: Course) {
        let cacheManager = SatelliteCacheManager.shared
        let existingCache = cacheManager.getCachedImages(for: course.id)

        // Case 1: Course has holes AND we have all crops cached
        if !course.holes.isEmpty,
           let cache = existingCache,
           cache.images.count == course.holes.count {
            let msg = "📱 [DataStore] All \(course.holes.count) holes already cached, transferring to Watch"
            print(msg)
            SatelliteLogHandler.shared.log(msg)
            SatelliteTransferManager.shared.transferImages(for: course.id) { success in
                if success {
                    let successMsg = "📱 [DataStore] ✅ Successfully transferred cached images"
                    print(successMsg)
                    SatelliteLogHandler.shared.log(successMsg)
                }
            }
            return
        }

        // Case 2: Course has holes BUT incomplete/missing cache
        if !course.holes.isEmpty {
            let msg = "📱 [DataStore] Course has \(course.holes.count) holes but incomplete cache, downloading..."
            print(msg)
            SatelliteLogHandler.shared.log(msg)

            guard let centerCoordinate = calculateCourseCentroid(course: course) else {
                let errorMsg = "📱 [DataStore] Cannot calculate centroid: no holes with coordinates"
                print(errorMsg)
                SatelliteLogHandler.shared.log(errorMsg)
                return
            }
            let centroidMsg = "📍 Center coordinate: (\(centerCoordinate.latitude), \(centerCoordinate.longitude))"
            print(centroidMsg)
            SatelliteLogHandler.shared.log(centroidMsg)

            cacheManager.downloadLargeSatelliteImage(centerCoordinate: centerCoordinate, courseId: course.id) { result in
                switch result {
                case .success(_):
                    let successMsg = "📱 [DataStore] Large image downloaded, cropping all holes..."
                    print(successMsg)
                    SatelliteLogHandler.shared.log(successMsg)
                    self.cropAndTransferHoleImages(for: course)
                case .failure(let error):
                    let errorMsg = "📱 [DataStore] ❌ Download failed: \(error.localizedDescription)"
                    print(errorMsg)
                    SatelliteLogHandler.shared.log(errorMsg)
                }
            }
            return
        }

        // Case 3: Course has NO holes yet (first-time user flow)
        if course.holes.isEmpty {
            // Download large image centered on user's current location
            guard let userLocation = LocationManager.shared.getCurrentLocation()?.coordinate else {
                let errorMsg = "📱 [DataStore] Cannot download satellite: no user location yet. Will download when first hole is added."
                print(errorMsg)
                SatelliteLogHandler.shared.log(errorMsg)
                return
            }

            let msg = "📱 [DataStore] Downloading satellite centered on user location (course has no holes yet)"
            print(msg)
            SatelliteLogHandler.shared.log(msg)

            let locationMsg = "📍 User location: (\(userLocation.latitude), \(userLocation.longitude))"
            print(locationMsg)
            SatelliteLogHandler.shared.log(locationMsg)

            cacheManager.downloadLargeSatelliteImage(centerCoordinate: userLocation, courseId: course.id) { result in
                switch result {
                case .success(_):
                    let successMsg = "📱 [DataStore] ✅ Large image ready, waiting for holes to be added..."
                    print(successMsg)
                    SatelliteLogHandler.shared.log(successMsg)
                    // Don't crop anything yet - holes will be added later
                case .failure(let error):
                    let errorMsg = "📱 [DataStore] ❌ Download failed: \(error.localizedDescription)"
                    print(errorMsg)
                    SatelliteLogHandler.shared.log(errorMsg)
                }
            }
            return
        }
    }

    private func calculateCourseCentroid(course: Course) -> CLLocationCoordinate2D? {
        // Only include holes that have coordinates
        let holesWithCoords = course.holes.compactMap { $0.coordinate }
        guard !holesWithCoords.isEmpty else { return nil }
        let avgLat = holesWithCoords.map { $0.latitude }.reduce(0, +) / Double(holesWithCoords.count)
        let avgLon = holesWithCoords.map { $0.longitude }.reduce(0, +) / Double(holesWithCoords.count)
        return CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
    }

    private func handleNewHoleAdded(courseId: UUID, hole: Hole, userLocation: CLLocationCoordinate2D? = nil) {
        let cacheManager = SatelliteCacheManager.shared

        // Only process holes that have coordinates
        guard let holeCoordinate = hole.coordinate else {
            let skipMsg = "📱 [DataStore] Hole #\(hole.number) has no coordinate yet, skipping satellite processing"
            print(skipMsg)
            SatelliteLogHandler.shared.log(skipMsg)
            return
        }

        let holeMsg = "🆕 New hole detected: #\(hole.number) at (\(holeCoordinate.latitude), \(holeCoordinate.longitude))"
        print(holeMsg)
        SatelliteLogHandler.shared.log(holeMsg)

        // Check if large image exists for this course
        let cache = cacheManager.getCachedImages(for: courseId)

        if cache?.largeImage == nil {
            // No large image exists yet - this is likely the first hole being added
            // Try to download the large image now that we have a coordinate
            let downloadMsg = "📱 [DataStore] No large satellite image yet. Downloading centered on hole #\(hole.number)..."
            print(downloadMsg)
            SatelliteLogHandler.shared.log(downloadMsg)

            cacheManager.downloadLargeSatelliteImage(centerCoordinate: holeCoordinate, courseId: courseId) { result in
                switch result {
                case .success(_):
                    let successMsg = "📱 [DataStore] ✅ Large image downloaded. Now cropping hole #\(hole.number)..."
                    print(successMsg)
                    SatelliteLogHandler.shared.log(successMsg)

                    // Now crop and transfer this hole
                    self.cropAndTransferSingleHole(courseId: courseId, hole: hole)

                case .failure(let error):
                    let errorMsg = "📱 [DataStore] ❌ Failed to download large image: \(error.localizedDescription)"
                    print(errorMsg)
                    SatelliteLogHandler.shared.log(errorMsg)
                }
            }
            return
        }

        // Check if we already have this hole's crop
        if let cache = cache, cache.images.contains(where: { $0.holeNumber == hole.number }) {
            let skipMsg = "📱 [DataStore] Hole \(hole.number) already has satellite crop, skipping"
            print(skipMsg)
            SatelliteLogHandler.shared.log(skipMsg)
            return
        }

        // Crop and transfer this hole's image
        cropAndTransferSingleHole(courseId: courseId, hole: hole, userLocation: userLocation)
    }

    private func cropAndTransferSingleHole(courseId: UUID, hole: Hole, userLocation: CLLocationCoordinate2D? = nil) {
        let cacheManager = SatelliteCacheManager.shared

        let cropMsg = "📱 [DataStore] Cropping satellite image for hole \(hole.number)"
        print(cropMsg)
        SatelliteLogHandler.shared.log(cropMsg)

        cacheManager.cropImageForHole(courseId: courseId, hole: hole, userLocation: userLocation) { result in
            switch result {
            case .success(_):
                let successMsg = "✂️ Successfully cropped hole \(hole.number)"
                print(successMsg)
                SatelliteLogHandler.shared.log(successMsg)

                SatelliteTransferManager.shared.transferHoleImage(courseId: courseId, holeNumber: hole.number) { success in
                    if success {
                        let transferMsg = "📱 [DataStore] ✅ Transferred satellite for hole \(hole.number)"
                        print(transferMsg)
                        SatelliteLogHandler.shared.log(transferMsg)
                    } else {
                        let failMsg = "📱 [DataStore] ⚠️ Failed to transfer satellite for hole \(hole.number)"
                        print(failMsg)
                        SatelliteLogHandler.shared.log(failMsg)
                    }
                }
            case .failure(let error):
                let errorMsg = "📱 [DataStore] ❌ Failed to crop hole \(hole.number): \(error.localizedDescription)"
                print(errorMsg)
                SatelliteLogHandler.shared.log(errorMsg)
            }
        }
    }

    private func cropAndTransferHoleImages(for course: Course) {
        let cacheManager = SatelliteCacheManager.shared
        let transferManager = SatelliteTransferManager.shared

        // Crop and transfer images sequentially for each hole
        func processHole(at index: Int) {
            guard index < course.holes.count else {
                print("📱 [DataStore] Finished cropping and transferring all hole images")
                return
            }

            let hole = course.holes[index]
            cacheManager.cropImageForHole(courseId: course.id, hole: hole) { result in
                switch result {
                case .success(_):
                    // Transfer this hole's image to Watch
                    guard cacheManager.getImageData(for: course.id, holeNumber: hole.number) != nil else {
                        print("📱 [DataStore] ERROR: No image data for hole \(hole.number)")
                        processHole(at: index + 1)
                        return
                    }

                    transferManager.transferHoleImage(courseId: course.id, holeNumber: hole.number) { success in
                        if success {
                            print("📱 [DataStore] Transferred hole \(hole.number) image to Watch")
                        }
                        // Continue with next hole
                        processHole(at: index + 1)
                    }
                case .failure(let error):
                    print("📱 [DataStore] Failed to crop hole \(hole.number): \(error)")
                    // Continue with next hole anyway
                    processHole(at: index + 1)
                }
            }
        }

        // Start processing from first hole
        processHole(at: 0)
    }

    func addStroke(to round: Round, holeNumber: Int, coordinate: CLLocationCoordinate2D, clubId: UUID, trajectoryHeading: Double? = nil) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
        let strokeNumber = strokesForHole.count + 1

        let stroke = Stroke(holeNumber: holeNumber, strokeNumber: strokeNumber, coordinate: coordinate, clubId: clubId, trajectoryHeading: trajectoryHeading)
        rounds[roundIndex].strokes.append(stroke)
        saveRounds()

        // Send updated round to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func updateStrokeDetails(in round: Round, stroke: Stroke, direction: StrokeDirection?) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        rounds[roundIndex].strokes[strokeIndex].direction = direction

        saveRounds()
    }

    func endRound(_ round: Round) {
        // Round is already saved, just need to ensure it's persisted
        saveRounds()
    }

    func deleteRound(_ round: Round) {
        rounds.removeAll { $0.id == round.id }
        saveRounds()
    }

    func hasRounds(for course: Course) -> Bool {
        return rounds.contains { $0.courseId == course.id }
    }

    func updateStrokePosition(in round: Round, stroke: Stroke, newCoordinate: CLLocationCoordinate2D) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        rounds[roundIndex].strokes[strokeIndex].latitude = newCoordinate.latitude
        rounds[roundIndex].strokes[strokeIndex].longitude = newCoordinate.longitude

        saveRounds()
    }

    func deleteStroke(in round: Round, stroke: Stroke) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        // Remove the stroke
        rounds[roundIndex].strokes.removeAll { $0.id == stroke.id }

        // Renumber remaining strokes for the same hole
        let holeNumber = stroke.holeNumber
        for i in rounds[roundIndex].strokes.indices {
            if rounds[roundIndex].strokes[i].holeNumber == holeNumber {
                // Recalculate stroke number based on position in filtered array
                let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
                if let indexInHole = strokesForHole.firstIndex(where: { $0.id == rounds[roundIndex].strokes[i].id }) {
                    rounds[roundIndex].strokes[i].strokeNumber = indexInHole + 1
                }
            }
        }

        saveRounds()

        // Send updated round to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func addPenaltyStroke(to round: Round, holeNumber: Int, coordinate: CLLocationCoordinate2D, clubId: UUID) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        let strokesForHole = rounds[roundIndex].strokes.filter { $0.holeNumber == holeNumber }
        let strokeNumber = strokesForHole.count + 1

        let stroke = Stroke(holeNumber: holeNumber, strokeNumber: strokeNumber, coordinate: coordinate, clubId: clubId, isPenalty: true)
        rounds[roundIndex].strokes.append(stroke)
        saveRounds()

        // Send updated round to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func renumberStroke(in round: Round, stroke: Stroke, newNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }),
              let strokeIndex = rounds[roundIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else { return }

        let oldNumber = rounds[roundIndex].strokes[strokeIndex].strokeNumber
        let holeNumber = stroke.holeNumber

        // If the number didn't change, do nothing
        guard oldNumber != newNumber else { return }

        // Update the stroke number
        rounds[roundIndex].strokes[strokeIndex].strokeNumber = newNumber

        // Adjust other stroke numbers for the same hole
        for i in rounds[roundIndex].strokes.indices {
            if rounds[roundIndex].strokes[i].holeNumber == holeNumber &&
               rounds[roundIndex].strokes[i].id != stroke.id {
                let currentNumber = rounds[roundIndex].strokes[i].strokeNumber

                if oldNumber < newNumber {
                    // Moving stroke later: decrease numbers in between
                    if currentNumber > oldNumber && currentNumber <= newNumber {
                        rounds[roundIndex].strokes[i].strokeNumber -= 1
                    }
                } else {
                    // Moving stroke earlier: increase numbers in between
                    if currentNumber >= newNumber && currentNumber < oldNumber {
                        rounds[roundIndex].strokes[i].strokeNumber += 1
                    }
                }
            }
        }

        saveRounds()
    }

    // MARK: - Round State Management (with automatic sync)

    func updateCurrentHoleIndex(for round: Round, newIndex: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].currentHoleIndex = newIndex
        saveRounds()

        // Sync to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func completeHole(in round: Round, holeNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].completedHoles.insert(holeNumber)
        saveRounds()

        // Sync to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    func reopenHole(in round: Round, holeNumber: Int) {
        guard let roundIndex = rounds.firstIndex(where: { $0.id == round.id }) else { return }

        rounds[roundIndex].completedHoles.remove(holeNumber)
        saveRounds()

        // Sync to Watch
        WatchConnectivityManager.shared.sendRound(rounds[roundIndex])
    }

    // MARK: - Club Type Management

    func addClubType(name: String) {
        let clubType = ClubTypeData(name: name, isDefault: false)
        clubTypes.append(clubType)
        saveClubTypes()
        print("🏌️ Added club type: \(name), total types: \(clubTypes.count)")
    }

    func deleteClubType(_ clubType: ClubTypeData) {
        // Don't allow deleting default types
        guard !clubType.isDefault else { return }

        clubTypes.removeAll { $0.id == clubType.id }

        // Remove all clubs that use this type
        availableClubs.removeAll { $0.clubTypeId == clubType.id }

        saveClubTypes()
        saveClubs()
    }

    func getClubType(byId id: UUID) -> ClubTypeData? {
        return clubTypes.first { $0.id == id }
    }

    func updateClubType(_ clubType: ClubTypeData, name: String) {
        guard let index = clubTypes.firstIndex(where: { $0.id == clubType.id }) else { return }
        clubTypes[index].name = name
        saveClubTypes()
    }

    func moveClubType(from source: IndexSet, to destination: Int) {
        clubTypes.move(fromOffsets: source, toOffset: destination)
        saveClubTypes()
    }

    // MARK: - Club Management

    func addCustomClub(name: String, clubTypeId: UUID) {
        let club = ClubData(name: name, clubTypeId: clubTypeId, isDefault: false)
        availableClubs.append(club)
        saveClubs()
    }

    func addCustomClubReturningId(name: String, clubTypeId: UUID) -> UUID {
        let club = ClubData(name: name, clubTypeId: clubTypeId, isDefault: false)
        availableClubs.append(club)
        saveClubs()
        return club.id
    }

    func updateClub(_ club: ClubData, name: String, clubTypeId: UUID) {
        guard let index = availableClubs.firstIndex(where: { $0.id == club.id }) else { return }
        availableClubs[index].name = name
        availableClubs[index].clubTypeId = clubTypeId
        saveClubs()
    }

    func moveClub(from source: IndexSet, to destination: Int) {
        availableClubs.move(fromOffsets: source, toOffset: destination)
        saveClubs()
    }

    func deleteClub(_ club: ClubData) {
        // Don't allow deleting default clubs
        guard !club.isDefault else { return }

        availableClubs.removeAll { $0.id == club.id }

        // Clear active club in any sets that used this club
        for i in 0..<clubSets.count {
            for j in 0..<clubSets[i].typeSelections.count {
                if clubSets[i].typeSelections[j].activeClubId == club.id {
                    clubSets[i].typeSelections[j].activeClubId = nil
                }
            }
        }

        saveClubs()
        saveClubSets()
    }

    func getClub(byId id: UUID) -> ClubData? {
        return availableClubs.first { $0.id == id }
    }

    func getClubs(forType typeId: UUID) -> [ClubData] {
        return availableClubs.filter { $0.clubTypeId == typeId }
    }

    // MARK: - Club Set Management

    func addClubSet(name: String, typeSelections: [TypeSelection]) {
        let clubSet = ClubSet(name: name, typeSelections: typeSelections, isActive: false)
        clubSets.append(clubSet)
        saveClubSets()
    }

    func updateClubSet(_ clubSet: ClubSet, name: String, typeSelections: [TypeSelection]) {
        guard let index = clubSets.firstIndex(where: { $0.id == clubSet.id }) else { return }

        clubSets[index].name = name
        clubSets[index].typeSelections = typeSelections
        clubSets[index].dateModified = Date()
        saveClubSets()
    }

    func setActiveClubForType(in clubSet: ClubSet, typeId: UUID, clubId: UUID?) {
        guard let setIndex = clubSets.firstIndex(where: { $0.id == clubSet.id }),
              let typeIndex = clubSets[setIndex].typeSelections.firstIndex(where: { $0.typeId == typeId }) else { return }

        clubSets[setIndex].typeSelections[typeIndex].activeClubId = clubId
        clubSets[setIndex].dateModified = Date()
        saveClubSets()
    }

    func deleteClubSet(_ clubSet: ClubSet) {
        clubSets.removeAll { $0.id == clubSet.id }
        saveClubSets()
    }

    func setActiveClubSet(_ clubSet: ClubSet) {
        for i in 0..<clubSets.count {
            clubSets[i].isActive = false
        }

        if let index = clubSets.firstIndex(where: { $0.id == clubSet.id }) {
            clubSets[index].isActive = true
        }

        saveClubSets()
    }

    var activeClubSet: ClubSet? {
        return clubSets.first { $0.isActive }
    }

    func getTypesInActiveSet() -> [ClubTypeData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            clubTypes.first { $0.id == selection.typeId }
        }
    }

    func getActiveClubForType(_ typeId: UUID) -> ClubData? {
        guard let activeSet = activeClubSet,
              let clubId = activeSet.getActiveClubId(for: typeId) else { return nil }
        return availableClubs.first { $0.id == clubId }
    }

    /// Returns only the clubs that are active in the current club set
    /// This filters to clubs where the type is in the set AND has an active club selected
    func getClubsInActiveSet() -> [ClubData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            guard let clubId = selection.activeClubId else { return nil }
            return availableClubs.first { $0.id == clubId }
        }
    }

    /// Returns the club types that are in the active set AND have an active club selected
    /// This is used for club selection UI during rounds
    func getTypesWithActiveClubs() -> [ClubTypeData] {
        guard let activeSet = activeClubSet else { return [] }
        return activeSet.typeSelections.compactMap { selection in
            // Only include types that have an active club selected
            guard selection.activeClubId != nil else { return nil }
            return clubTypes.first { $0.id == selection.typeId }
        }
    }
}

struct HoleDetectionRunState {
    var isRunning: Bool
    var message: String
    var progress: Double
    var error: String?
}

private struct HoleDetectionDiagnostics {
    var tileCount: Int
    var totalGreenPixels: Int
    var totalGreenishPixels: Int
    var totalSwappedChannelExactPixels: Int
    var preMergeBlobCount: Int
    var mergedBlobCount: Int
    var topGreenishColors: [HoleDetectionColorCount]

    var summaryMessage: String {
        "Hole detection ready (\(totalGreenPixels) exact px, \(totalGreenishPixels) greenish px, \(mergedBlobCount) blobs)"
    }
}

private struct HoleDetectionAnalyzeResult {
    var data: CourseHoleDetectionData
    var diagnostics: HoleDetectionDiagnostics
}

private struct HoleDetectionRGB {
    var r: Int
    var g: Int
    var b: Int

    var formatted: String {
        "\(r),\(g),\(b)"
    }
}

private struct HoleDetectionColorCount {
    var color: HoleDetectionRGB
    var count: Int

    var formatted: String {
        "rgb(\(color.formatted))=\(count)"
    }
}

private struct HoleDetectionTileResult {
    var blobs: [HoleDetectionBlob]
    var greenPixelCount: Int
    var greenishPixelCount: Int
    var swappedChannelExactCount: Int
    var greenishColorCounts: [UInt32: Int]
}

private final class HoleDetectionAnalyzer {
    // Exact standard-map green/tee fill from iPhone snapshots.
    private let greenColor = (r: 186, g: 232, b: 153)
    private let sandColor = (r: 245, g: 242, b: 218)
    private let sandTolerance = 10
    private let sandScanRadius = 20
    private let sandWeight = 1.0
    private let areaWeight = 0.2
    private let widthWeight = 1.0

    private let tileDiameterMeters: Double = 2000.0
    private let tileSpacingMeters: Double = 1800.0
    private let tilePixelSize = 1600
    private let duplicateDistanceMeters: Double = 18.0
    private let minimumRawArea = 20
    private let maxPolygonPoints = 24
    private let diagnosticsTopColorLimit = 10
    private let diagnosticsColorCountThreshold = 1000

    func detect(
        courseId: UUID,
        center: CLLocationCoordinate2D,
        coverageRadiusMeters: Double,
        progress: @escaping (String, Double) -> Void,
        completion: @escaping (Result<HoleDetectionAnalyzeResult, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tileCenters = self.buildTileCenters(center: center, coverageRadiusMeters: coverageRadiusMeters)
                var blobs: [HoleDetectionBlob] = []
                let totalTiles = max(tileCenters.count, 1)
                var totalGreenPixels = 0
                var totalGreenishPixels = 0
                var totalSwappedChannelExactPixels = 0
                var mergedGreenishColorCounts: [UInt32: Int] = [:]

                for (index, tileCenter) in tileCenters.enumerated() {
                    let progressValue = Double(index) / Double(totalTiles)
                    progress("Scanning map \(index + 1)/\(totalTiles)...", progressValue)

                    let snapshotImage = try self.snapshotStandardMap(center: tileCenter)
                    let tileResult = self.detectBlobs(
                        in: snapshotImage,
                        tileCenter: tileCenter,
                        tileDiameterMeters: self.tileDiameterMeters
                    )
                    blobs.append(contentsOf: tileResult.blobs)
                    totalGreenPixels += tileResult.greenPixelCount
                    totalGreenishPixels += tileResult.greenishPixelCount
                    totalSwappedChannelExactPixels += tileResult.swappedChannelExactCount
                    for (color, count) in tileResult.greenishColorCounts {
                        mergedGreenishColorCounts[color, default: 0] += count
                    }

                    let tileMessage = "Tile \(index + 1)/\(totalTiles): exact \(tileResult.greenPixelCount) px, greenish \(tileResult.greenishPixelCount) px, swapped \(tileResult.swappedChannelExactCount), blobs \(tileResult.blobs.count)"
                    progress(tileMessage, min(progressValue + (0.8 / Double(totalTiles)), 0.94))
                }

                progress("Merging overlaps...", 0.95)
                let mergedBlobs = self.mergeDuplicateBlobs(blobs)

                let data = CourseHoleDetectionData(
                    courseId: courseId,
                    generatedAt: Date(),
                    blobs: mergedBlobs
                )
                let topGreenishColors = mergedGreenishColorCounts
                    .filter { $0.value >= self.diagnosticsColorCountThreshold }
                    .sorted {
                        if $0.value == $1.value { return $0.key < $1.key }
                        return $0.value > $1.value
                    }
                    .prefix(self.diagnosticsTopColorLimit)
                    .map {
                        HoleDetectionColorCount(
                            color: self.unpackRGB($0.key),
                            count: $0.value
                        )
                    }

                let diagnostics = HoleDetectionDiagnostics(
                    tileCount: tileCenters.count,
                    totalGreenPixels: totalGreenPixels,
                    totalGreenishPixels: totalGreenishPixels,
                    totalSwappedChannelExactPixels: totalSwappedChannelExactPixels,
                    preMergeBlobCount: blobs.count,
                    mergedBlobCount: mergedBlobs.count,
                    topGreenishColors: topGreenishColors
                )

                progress(diagnostics.summaryMessage, 1.0)
                completion(.success(HoleDetectionAnalyzeResult(
                    data: data,
                    diagnostics: diagnostics
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func buildTileCenters(center: CLLocationCoordinate2D, coverageRadiusMeters: Double) -> [CLLocationCoordinate2D] {
        let tileRadius = tileDiameterMeters / 2
        let neededSteps = Int(ceil(max(0, coverageRadiusMeters - tileRadius) / tileSpacingMeters))
        let stepCount = max(1, min(2, neededSteps))

        var centers: [CLLocationCoordinate2D] = []
        for y in (-stepCount)...stepCount {
            for x in (-stepCount)...stepCount {
                let northMeters = Double(y) * tileSpacingMeters
                let eastMeters = Double(x) * tileSpacingMeters
                centers.append(offsetCoordinate(from: center, northMeters: northMeters, eastMeters: eastMeters))
            }
        }
        return centers
    }

    private func snapshotStandardMap(center: CLLocationCoordinate2D) throws -> CGImage {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: tileDiameterMeters,
            longitudinalMeters: tileDiameterMeters
        )
        options.size = CGSize(width: tilePixelSize, height: tilePixelSize)
        options.mapType = .standard
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll
        // Force light mode and 1x scale so the green fill color (186,232,153) matches
        // regardless of the device's appearance setting or display scale.
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(displayScale: 1.0)
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var capturedImage: CGImage?
        var capturedError: Error?

        // MKMapSnapshotter must be created and started on the main thread.
        // The completion handler is also delivered on main, which is fine
        // since we only block the background thread with the semaphore.
        DispatchQueue.main.async {
            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { snapshot, error in
                if let error = error {
                    capturedError = error
                } else {
                    capturedImage = snapshot?.image.cgImage
                }
                semaphore.signal()
            }
        }

        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            throw NSError(
                domain: "HoleDetectionAnalyzer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Map snapshot timed out"]
            )
        }

        if let error = capturedError {
            throw error
        }

        guard let image = capturedImage else {
            throw NSError(
                domain: "HoleDetectionAnalyzer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No map snapshot image returned"]
            )
        }

        return image
    }

    private func detectBlobs(
        in image: CGImage,
        tileCenter: CLLocationCoordinate2D,
        tileDiameterMeters: Double
    ) -> HoleDetectionTileResult {
        let width = image.width
        let height = image.height
        let pixelCount = width * height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: pixelCount * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return HoleDetectionTileResult(
                blobs: [],
                greenPixelCount: 0,
                greenishPixelCount: 0,
                swappedChannelExactCount: 0,
                greenishColorCounts: [:]
            )
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var isGreen = [Bool](repeating: false, count: pixelCount)
        var greenPixelCount = 0
        var greenishPixelCount = 0
        var swappedChannelExactCount = 0
        var greenishColorCounts: [UInt32: Int] = [:]
        for idx in 0..<pixelCount {
            let offset = idx * 4
            let r = Int(pixelData[offset])
            let g = Int(pixelData[offset + 1])
            let b = Int(pixelData[offset + 2])
            let isGreenPixel = (r == greenColor.r && g == greenColor.g && b == greenColor.b)
            isGreen[idx] = isGreenPixel
            if isGreenPixel {
                greenPixelCount += 1
            }
            if b == greenColor.r && g == greenColor.g && r == greenColor.b {
                swappedChannelExactCount += 1
            }
            if g >= 90 && g > r + 8 && g > b + 8 {
                greenishPixelCount += 1
                let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
                greenishColorCounts[key, default: 0] += 1
            }
        }

        var visited = [Bool](repeating: false, count: pixelCount)
        let metersPerPixel = tileDiameterMeters / Double(width)
        var detected: [HoleDetectionBlob] = []

        for start in 0..<pixelCount {
            if !isGreen[start] || visited[start] { continue }

            var queue: [Int] = [start]
            visited[start] = true
            var queueIndex = 0

            var area = 0
            var sumX = 0
            var sumY = 0
            var minX = Int.max
            var maxX = Int.min
            var minY = Int.max
            var maxY = Int.min
            var boundaryPoints: [(x: Int, y: Int)] = []

            while queueIndex < queue.count {
                let current = queue[queueIndex]
                queueIndex += 1

                let x = current % width
                let y = current / width

                area += 1
                sumX += x
                sumY += y
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                var isBoundaryPixel = false
                let neighbors = [
                    (x: x + 1, y: y),
                    (x: x - 1, y: y),
                    (x: x, y: y + 1),
                    (x: x, y: y - 1)
                ]

                for n in neighbors {
                    guard n.x >= 0, n.x < width, n.y >= 0, n.y < height else {
                        isBoundaryPixel = true
                        continue
                    }

                    let nIdx = n.y * width + n.x
                    if !isGreen[nIdx] {
                        isBoundaryPixel = true
                        continue
                    }

                    if !visited[nIdx] {
                        visited[nIdx] = true
                        queue.append(nIdx)
                    }
                }

                if isBoundaryPixel {
                    boundaryPoints.append((x: x, y: y))
                }
            }

            if area < minimumRawArea { continue }

            let blobWidth = max(1, maxX - minX + 1)
            let blobHeight = max(1, maxY - minY + 1)
            let minWidth = Double(min(blobWidth, blobHeight))
            let maxWidth = Double(max(blobWidth, blobHeight))
            let elongation = maxWidth / max(minWidth, 1.0)
            let centroidX = Double(sumX) / Double(area)
            let centroidY = Double(sumY) / Double(area)

            let sandPixels = countSandPixels(
                aroundMinX: minX,
                minY: minY,
                maxX: maxX,
                maxY: maxY,
                pixelData: pixelData,
                width: width,
                height: height
            )

            let greenness = calculateGreennessScore(
                area: area,
                minWidth: minWidth,
                elongation: elongation,
                sandPixels: sandPixels
            )

            let hull = convexHull(points: boundaryPoints)
            let reducedHull = reducePoints(hull, maxPoints: maxPolygonPoints)
            let polygonPoints: [MapPoint]
            if reducedHull.count >= 3 {
                polygonPoints = reducedHull.map {
                    MapPoint(pixelToCoordinate(
                        x: Double($0.x),
                        y: Double($0.y),
                        tileCenter: tileCenter,
                        imageWidth: Double(width),
                        imageHeight: Double(height),
                        metersPerPixel: metersPerPixel
                    ))
                }
            } else {
                // Fall back to a small box around centroid if hull is too small.
                let halfSize = 2.0
                let fallbackPixels = [
                    (centroidX - halfSize, centroidY - halfSize),
                    (centroidX + halfSize, centroidY - halfSize),
                    (centroidX + halfSize, centroidY + halfSize),
                    (centroidX - halfSize, centroidY + halfSize)
                ]
                polygonPoints = fallbackPixels.map {
                    MapPoint(pixelToCoordinate(
                        x: $0.0,
                        y: $0.1,
                        tileCenter: tileCenter,
                        imageWidth: Double(width),
                        imageHeight: Double(height),
                        metersPerPixel: metersPerPixel
                    ))
                }
            }

            let centroidCoordinate = pixelToCoordinate(
                x: centroidX,
                y: centroidY,
                tileCenter: tileCenter,
                imageWidth: Double(width),
                imageHeight: Double(height),
                metersPerPixel: metersPerPixel
            )

            detected.append(HoleDetectionBlob(
                area: area,
                minWidth: minWidth,
                elongation: elongation,
                greennessScore: greenness,
                centroidLatitude: centroidCoordinate.latitude,
                centroidLongitude: centroidCoordinate.longitude,
                polygon: polygonPoints
            ))
        }

        return HoleDetectionTileResult(
            blobs: detected,
            greenPixelCount: greenPixelCount,
            greenishPixelCount: greenishPixelCount,
            swappedChannelExactCount: swappedChannelExactCount,
            greenishColorCounts: greenishColorCounts
        )
    }

    private func unpackRGB(_ key: UInt32) -> HoleDetectionRGB {
        HoleDetectionRGB(
            r: Int((key >> 16) & 0xFF),
            g: Int((key >> 8) & 0xFF),
            b: Int(key & 0xFF)
        )
    }

    private func countSandPixels(
        aroundMinX minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int,
        pixelData: [UInt8],
        width: Int,
        height: Int
    ) -> Int {
        let startX = max(0, minX - sandScanRadius)
        let endX = min(width - 1, maxX + sandScanRadius)
        let startY = max(0, minY - sandScanRadius)
        let endY = min(height - 1, maxY + sandScanRadius)

        var sandPixels = 0
        for y in stride(from: startY, through: endY, by: 2) {
            for x in stride(from: startX, through: endX, by: 2) {
                let offset = (y * width + x) * 4
                let r = Int(pixelData[offset])
                let g = Int(pixelData[offset + 1])
                let b = Int(pixelData[offset + 2])
                if abs(r - sandColor.r) <= sandTolerance &&
                    abs(g - sandColor.g) <= sandTolerance &&
                    abs(b - sandColor.b) <= sandTolerance {
                    sandPixels += 1
                }
            }
        }

        // Mirror the stride compensation used in HoleDetect.
        return sandPixels * 4
    }

    private func calculateGreennessScore(area: Int, minWidth: Double, elongation: Double, sandPixels: Int) -> Int {
        let sandContrib = Double(sandPixels) * sandWeight
        let areaContrib = Double(area) * areaWeight
        let widthContrib = minWidth * widthWeight
        let elongationPenalty = max(elongation * elongation, 1.0e-6)
        let greenness = (sandContrib + areaContrib + widthContrib) / elongationPenalty
        return Int(round(greenness))
    }

    private func mergeDuplicateBlobs(_ blobs: [HoleDetectionBlob]) -> [HoleDetectionBlob] {
        let sorted = blobs.sorted {
            if $0.greennessScore == $1.greennessScore {
                return $0.area > $1.area
            }
            return $0.greennessScore > $1.greennessScore
        }

        var merged: [HoleDetectionBlob] = []
        for blob in sorted {
            if let matchIndex = merged.firstIndex(where: {
                distanceMeters(
                    CLLocationCoordinate2D(latitude: $0.centroidLatitude, longitude: $0.centroidLongitude),
                    CLLocationCoordinate2D(latitude: blob.centroidLatitude, longitude: blob.centroidLongitude)
                ) < duplicateDistanceMeters
            }) {
                let existing = merged[matchIndex]
                if blob.greennessScore > existing.greennessScore ||
                    (blob.greennessScore == existing.greennessScore && blob.area > existing.area) {
                    merged[matchIndex] = blob
                }
            } else {
                merged.append(blob)
            }
        }
        return merged
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return aLoc.distance(from: bLoc)
    }

    private func pixelToCoordinate(
        x: Double,
        y: Double,
        tileCenter: CLLocationCoordinate2D,
        imageWidth: Double,
        imageHeight: Double,
        metersPerPixel: Double
    ) -> CLLocationCoordinate2D {
        let pixelOffsetX = x - (imageWidth / 2.0)
        let pixelOffsetY = y - (imageHeight / 2.0)

        let metersEast = pixelOffsetX * metersPerPixel
        let metersNorth = -pixelOffsetY * metersPerPixel

        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(tileCenter.latitude * .pi / 180.0)

        return CLLocationCoordinate2D(
            latitude: tileCenter.latitude + (metersNorth / metersPerDegreeLat),
            longitude: tileCenter.longitude + (metersEast / metersPerDegreeLon)
        )
    }

    private func offsetCoordinate(from coordinate: CLLocationCoordinate2D, northMeters: Double, eastMeters: Double) -> CLLocationCoordinate2D {
        let metersPerDegreeLat = 111000.0
        let metersPerDegreeLon = 111000.0 * cos(coordinate.latitude * .pi / 180.0)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + (northMeters / metersPerDegreeLat),
            longitude: coordinate.longitude + (eastMeters / metersPerDegreeLon)
        )
    }

    private func convexHull(points: [(x: Int, y: Int)]) -> [(x: Int, y: Int)] {
        guard points.count >= 3 else { return points }

        let sorted = points.sorted { lhs, rhs in
            lhs.x < rhs.x || (lhs.x == rhs.x && lhs.y < rhs.y)
        }

        func cross(_ a: (x: Int, y: Int), _ b: (x: Int, y: Int), _ c: (x: Int, y: Int)) -> Int {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }

        var lower: [(x: Int, y: Int)] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                _ = lower.popLast()
            }
            lower.append(point)
        }

        var upper: [(x: Int, y: Int)] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                _ = upper.popLast()
            }
            upper.append(point)
        }

        _ = lower.popLast()
        _ = upper.popLast()
        return lower + upper
    }

    private func reducePoints(_ points: [(x: Int, y: Int)], maxPoints: Int) -> [(x: Int, y: Int)] {
        guard points.count > maxPoints, maxPoints > 2 else { return points }
        var reduced: [(x: Int, y: Int)] = []
        let step = Double(points.count) / Double(maxPoints)
        for i in 0..<maxPoints {
            let index = min(points.count - 1, Int((Double(i) * step).rounded(.down)))
            reduced.append(points[index])
        }
        return reduced
    }
}
