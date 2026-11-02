# StrokeSaver

A comprehensive golf tracking application for iOS and Apple Watch that provides real-time GPS-based distance tracking, stroke recording, and advanced motion detection for swing analysis.

> **Naming:** the product is **StrokeSaver** (distributed through TestFlight; App Store Connect app id `6756589450`). The Xcode
> project, targets, source directories, bundle identifiers (`com.Jared.GolfTracker`), this repo, and the
> support site keep the original `GolfTracker` name — they are internal identifiers and must not be
> renamed. Anything a user reads says StrokeSaver.

## Overview

StrokeSaver is a native SwiftUI application that helps golfers track their rounds with precision. The app features a companion Apple Watch app for hands-free operation and sophisticated motion detection capabilities for automatic swing tracking.

## Platforms & Requirements

- **iOS**: iPhone running iOS 17.0+
- **watchOS**: Apple Watch running watchOS 10.0+
- **Xcode**: 15.4+
- **Swift**: 5.0

## Architecture

The application consists of two main targets:
1. `GolfTracker` target (iOS app) - Full-featured interface with course management, round history, and detailed shot tracking
2. **GolfWatch Watch App** - Companion watchOS app for on-course tracking with motion detection

Both apps communicate via **WatchConnectivity** framework for real-time data synchronization.

## Tests

    cd Tests/AppLogic && swift test

The app's rule logic (statistics, which copy of a synced row wins, the watch's motion buffer),
compiled from the app's own source files as a plain Swift package; CI runs it on every push to
`main`. `supabase/tests/holes_rls.sh` checks the course-hole access rules against the live project
and needs the service-role key. `CLAUDE.md` § Tests has the full list.

## Algorithms

Swing detection, swing direction and the elevation solver are kept in a private package. This repository contains the interfaces the app calls them through.

## Core Features

### 1. Course Management

#### Course Creation & Editing
- Create new golf courses with custom names
- Add course metadata: rating, slope, and city
- Course editor view for managing holes
- View course details including all holes
- Delete courses (with cascade deletion of associated rounds)

**Location**: `GolfTracker/Views/Courses/`
- `CourseListView.swift`: Browse and manage all courses
- `CourseEditorView.swift`: Create and edit courses
- `CourseDetailView.swift`: View course information

#### Hole Management
- Add holes to courses with GPS coordinates
- Set par for each hole (3, 4, or 5)
- Edit hole locations by moving to current position or manual placement
- Visual map-based hole positioning
- Automatic hole numbering

### 2. Round Tracking

#### Round Creation & Management
- Start a new round from any course
- Resume incomplete rounds
- Track current hole index across devices
- Mark holes as completed
- View complete round history
- Round details showing all strokes, clubs used, and scores

**Location**: `GolfTracker/Views/Rounds/`
- `RoundsHistoryView.swift`: View all completed rounds
- `RoundDetailView.swift`: Detailed round statistics and stroke-by-stroke analysis

#### Round Data
- Date and time of round
- Course association
- Stroke-by-stroke tracking
- Target markers per hole
- Completed holes tracking
- Synchronized current hole index between iPhone and Watch

### 3. Shot Tracking & Recording

#### GPS-Based Stroke Recording
- Record strokes at current GPS location
- Automatic distance calculation to hole
- Club selection (21 club types including specialty shots)
- Stroke trajectory heading capture
- Penalty stroke placement
- Undo last action functionality

**Location**: `GolfTracker/Views/Play/HolePlayView.swift`

#### Club Types
- Driver, Hybrid
- Irons: 3i through 9i
- Wedges: Pitching Wedge, Attack Wedge, Sand Wedge
- Specialty: Putter, Pitch, Chip, Partial, Punch

**Location**: `GolfTracker/Models/Models.swift` (lines 4-22)

#### Stroke Direction Tracking
- Five-level shot accuracy system:
  - Red Right (severe right)
  - Yellow Right (slight right)
  - Center (straight)
  - Yellow Left (slight left)
  - Red Left (severe left)

**Location**: `GolfTracker/Models/Models.swift` (lines 25-47)

#### Advanced Stroke Features
- **Trajectory Heading**: Capture the direction you're aiming before hitting
  - Visual aim arrow showing offset from target line
  - Blue direction button to capture current heading
  - Automatic fallback to hole bearing if not set
- **Penalty Strokes**: Place penalty strokes anywhere on the course with visual marker
- **Stroke Editing**: Move stroke positions, delete strokes, view stroke details

**Location**: `GolfTracker/Views/Play/StrokeDetailsView.swift`

### 4. Live Play Interface

#### Interactive Map View
- Real-time map showing hole, user location, and all strokes
- Two map modes: Standard map and Satellite imagery
- Auto-rotating map with hole always at top, user at bottom
- Dynamic zoom based on distance to hole
- Tap-to-select strokes for editing
- Tap hole marker to reposition

**Location**: `GolfTracker/Views/Play/HoleMapView.swift`

#### Overlay Controls
- Current hole number and par
- Stroke count for current hole
- Real-time distance to hole in yards
- Previous/Next hole navigation
- Add new hole button when needed

**Location**: `GolfTracker/Views/Play/HoleOverlayControls.swift`

#### Floating Action Buttons
- **Record Stroke**: Green button to add a shot at current location
- **Aim Direction**: Blue button to capture trajectory heading
- **Target Placement**: Scope button to place/remove target markers
- **Penalty Stroke**: Orange button to add penalty strokes
- **Undo**: Remove last stroke or reopen completed hole
- **Finish Hole**: Mark current hole as complete

**Location**: `GolfTracker/Views/Play/FloatingButtonsView.swift`

#### Target System
- Place multiple target markers per hole
- Tap map to add/remove targets
- Real-time distance display to each target in yards
- Yellow scope icon markers
- Synchronized across iPhone and Watch

### 5. Apple Watch Integration

#### Watch Connectivity
- Real-time bidirectional sync between iPhone and Watch
- Round data synchronization
- Hole navigation sync
- Stroke sync (both directions)
- Target marker sync
- Course and hole data transfer
- Connection status monitoring

**Location**: `GolfTracker/Services/WatchConnectivityManager.swift` (message types in `WatchMessages.swift`)

#### Watch App Features
- Standalone round tracking
- GPS distance calculation
- Digital Crown club selection
- On-wrist stroke recording
- Target placement via map tap
- Penalty stroke placement
- Undo functionality
- Hole navigation
- Add/edit holes
- Full view mode toggle
- Motion sensor testing

**Location**: `GolfWatch Watch App/Views/ActiveRoundView.swift`

#### Watch UI Components
- Distance to hole (large display)
- Current hole number and par
- Stroke count
- Club selector (Digital Crown controlled)
- Action buttons overlay:
  - Green stroke button (+ primary action)
  - Blue aim direction button
  - Yellow target placement button
  - Orange penalty stroke button
- Swipe-up menu for advanced actions
- Haptic feedback for all interactions

#### Watch Hole Management
- Add new holes from watch
- Edit existing hole positions
- Set hole par (3, 4, or 5)
- Manual hole placement with map interaction
- Synchronized with iPhone

**Location**: `GolfWatch Watch App/Views/AddHoleNavigationView.swift`, `EditHoleView.swift`

### 7. Motion Detection & Swing Analysis

#### Swing Detection System (`unifDetect`)
- CoreMotion device motion at **100Hz** (primary) + CMBatchedSensorManager raw accel at **800Hz** (putt-only fallback)
- Single `UnifiedDetector` with tri-state classification (putt / swing / ambig) and type-aware pairing
- Two-stage post-pairing contact gate: 100Hz device-motion `userAccel` primary, 800Hz raw-accel override when putter is selected
- Dynamic 800Hz gating: only spins up at setup-start with putter selected, auto-stops 3s after setup-end if no pending shapes — preserves battery
- Data Collection Mode for building labeled training corpus; false-positive logging when a detected stroke is undone

**Location**: `GolfWatch Watch App/Services/SwingDetectionManager.swift` (orchestration); the detector itself is in the algorithms package (see Algorithms).

#### Motion Data Recording
- Record full motion data sessions
- Capture 15 device-motion channels (userAccel X/Y/Z/Mag, rotation X/Y/Z/Mag, gravity X/Y/Z, pitch/roll/yaw) plus 4 raw-accel channels (X/Y/Z/Mag @ 800Hz)
- CSV export format
- Transfer recorded data to iPhone via WatchConnectivity
- Min/max value tracking
- Freeze/unfreeze tracking for analysis

#### Motion Test View
- Real-time acceleration + rotation + attitude display
- Min/max value monitoring with freeze/unfreeze
- Start/stop full motion recording
- Send data to iPhone
- `unifDetect` parameter tuning (presets + per-gate overrides)
- Data Collection Mode entry point
- Last-swing detail panel

**Location**: `GolfWatch Watch App/Views/AccelTestView.swift`

#### Motion Data Analysis (iPhone)
- Receive CSV motion data from Watch
- Save to documents directory with timestamp
- View saved motion files
- Export/share motion data
- File size and date display

**Location**: `GolfTracker/Views/Test/TestFilesView.swift`

### 8. HealthKit Integration

#### Workout Tracking
- Automatic workout session start on round begin
- Golf workout type
- Heart rate monitoring
- Active calorie tracking
- Distance tracking
- Workout duration
- Auto-pause/resume support
- Background tracking support
- Automatic workout end on round completion

**Location**: `GolfWatch Watch App/Services/WorkoutManager.swift`

#### Health Permissions
- Request HealthKit authorization
- Heart rate data access
- Active energy burned
- Distance walking/running
- Workout sessions

### 9. Location Services

#### GPS Tracking
- CoreLocation integration
- When-in-use location permission
- Background location support
- Real-time location updates
- Heading/compass support
- Distance calculations (meters to yards)
- Bearing calculations between coordinates
- Location accuracy monitoring

**Location**: `GolfTracker/Services/LocationManager.swift`

#### Distance Calculations
- Real-time distance to hole in yards
- Distance between strokes
- Distance to target markers
- Formatted distance display
- Coordinate-based calculations using Haversine formula

**Location**: `GolfTracker/Helpers/MapCalculations.swift`

### 10. Data Persistence

#### Local Storage
- JSON-based data persistence
- Course data storage
- Round history storage
- Watch data store (separate for watchOS)
- Automatic save on changes
- File-based storage in documents directory

**Location**: `GolfTracker/Services/DataStore.swift` and its `DataStore+*.swift` extensions

#### Data Models
Comprehensive data structures for:
- **Course**: ID, name, holes, rating, slope, city
- **Hole**: ID, number, coordinates, par
- **Stroke**: ID, hole number, stroke number, coordinates, club, timestamp, penalty flag, trajectory heading
- **Target**: ID, hole number, coordinates
- **Round**: ID, course ID, course name, date, strokes, holes, completed holes, current hole index, targets
**Location**: `GolfTracker/Models/Models.swift`

### 11. Map Features

#### Map Annotations
- Custom hole markers (flag icons)
- User location marker with heading arrow
- Stroke number markers (white circles)
- Penalty stroke markers (orange circles)
- Target markers (scope icons)
- Trajectory lines (when available)
- Distance labels

**Location**: `GolfTracker/Views/Shared/MapAnnotations.swift`

#### Map Camera Controls
- Auto-rotating map (hole at top)
- Dynamic zoom based on content
- Smooth camera transitions
- Bearing-based rotation
- Center point calculation between user and hole
- Full hole view mode (shows all strokes)
- User-to-hole view mode (default)

**Location**: `GolfTracker/Views/Play/HolePlayView.swift`

### 12. Edit Modes

#### Hole Position Editing
- Move hole to current GPS location
- Manual hole placement with map interaction
- Confirmation dialog before moving
- Save/cancel options
- Visual temporary position marker
- Return to previous map view on cancel

**Location**: `GolfTracker/Views/Play/Components/EditModeViews.swift`

#### Stroke Position Editing
- Select stroke to edit from details view
- Tap map to reposition stroke
- Visual temporary position marker
- Save/cancel controls
- Preserve stroke metadata (club, timestamp, etc.)

#### Penalty Stroke Placement
- Enter placement mode
- Tap map to set position
- Visual confirmation
- Uses club from most recent stroke
- Auto-incrementing stroke number
- Save/cancel options

### 13. Navigation & UI

#### Tab-Based Navigation (iPhone)
- Courses tab: Browse and manage courses
- History tab: View round history
- Tests tab: Motion data analysis tools

**Location**: `GolfTracker/Views/ContentView.swift`

#### Toolbar Actions
- Map style toggle (standard/satellite)
- View toggle (update map position)
- Edit hole position
- Course editor access

#### Watch Navigation
- Main view: Active round interface
- Swipe-up sheet: Advanced actions and settings
- Navigation to add/edit hole screens
- Motion test navigation
- Automatic navigation on hole completion

## Technical Details

### Frameworks & Technologies
- **SwiftUI**: Modern declarative UI framework
- **MapKit**: Maps and annotations
- **CoreLocation**: GPS tracking and distance calculations
- **CoreMotion**: Accelerometer and gyroscope data (Watch)
- **WatchConnectivity**: iPhone-Watch communication
- **HealthKit**: Workout tracking (Watch)
- **Combine**: Reactive programming for data flow

### Key Design Patterns
- **MVVM**: ObservableObject stores for state management
- **Singleton**: Shared managers (Location, WatchConnectivity, SwingDetection)
- **Delegate**: Location and motion updates
- **Publisher-Subscriber**: Combine for data observation

### Performance Optimizations
- Background queue for motion processing (`motionQueue` + separate `rawAccelQueue`)
- Sensor-time-based detection (avoids wall-clock drift during CMBatchedSensorManager bursts)
- GPS power modes (full / moderate / off) driven by distance to hole and club selection
- 800Hz raw accel only runs during putter setup + contact windows
- `#if DEBUG`-gated logging via `dprint` helper (zero release-build cost)
- Ring-buffered continuous + swing-data logs with capacity caps

### Cross-Platform Sync
- Automatic round synchronization
- Bidirectional stroke updates
- Hole navigation sync
- Target marker sync
- Course and hole data transfer
- Reachability checking
- Error handling and retry logic

## Data Flow

### iPhone → Watch
1. User starts round on iPhone
2. Round data sent via WatchConnectivity
3. Watch receives and displays active round
4. Map updates with hole and user location

### Watch → iPhone
1. User records stroke on Watch
2. Stroke data sent via WatchConnectivity
3. iPhone receives and updates round
4. UI refreshes to show new stroke

### Bidirectional
- Hole navigation syncs in both directions
- Target placement syncs immediately
- Hole creation/editing syncs automatically
- Round completion status syncs

## Permissions Required

### iOS
- **Location When In Use**: Track position during rounds
- **Location Always**: Background location tracking during rounds

### watchOS
- **Location**: Distance calculations and stroke positioning
- **HealthKit**: Workout tracking and health data
- **Motion**: Swing detection via accelerometer and gyroscope

## File Structure

```
GolfTracker/                              # iOS app target
├── App/GolfTrackerApp.swift              # iOS app entry point
├── Models/
│   ├── Models.swift                      # Shared data models (iOS + Watch)
│   └── PlayerStats.swift                 # Player statistics models
├── Views/
│   ├── ContentView.swift                 # Main tab view
│   ├── Home/                             # Home & club management
│   ├── Courses/                          # Course management views
│   ├── Rounds/                           # Round history views
│   ├── Play/                             # Active play views
│   │   ├── HolePlayView.swift
│   │   ├── HoleMapView.swift
│   │   ├── HoleOverlayControls.swift
│   │   ├── FloatingButtonsView.swift
│   │   ├── StrokeDetailsView.swift
│   │   ├── InRoundScorecardView.swift
│   │   └── Components/
│   ├── Stats/StatsView.swift             # Statistics dashboard
│   ├── Shared/MapAnnotations.swift
│   └── Test/TestFilesView.swift
├── Services/
│   ├── DataStore.swift                   # Data persistence (+ DataStore+*.swift per concern)
│   ├── LocationManager.swift             # GPS services
│   ├── StatsEngine.swift                 # Statistics calculations
│   └── WatchConnectivityManager.swift    # iPhone-Watch sync
├── Helpers/MapCalculations.swift
└── Info.plist

GolfWatch Watch App/                      # watchOS app target
├── GolfWatchApp.swift                    # Watch app entry point
├── ContentView.swift                     # Main Watch view
├── Views/
│   ├── WatchHomeView.swift               # Watch home screen
│   ├── ActiveRoundView.swift             # Primary play interface
│   ├── AccelTestView.swift               # Motion testing
│   ├── OptionsView.swift                 # Settings menu
│   ├── EditHoleView.swift
│   ├── AddHoleNavigationView.swift
│   ├── ClubRecommendSettingsView.swift
│   ├── PredictGreenSettingsView.swift
│   └── ViewSettingsView.swift
├── Services/
│   ├── WatchDataStore.swift              # Watch data persistence (+ WatchDataStore+*.swift per concern)
│   ├── SwingDetectionManager.swift       # Motion detection orchestrator (+ SwingDetectionManager+*.swift)
│   ├── DetectorConfig.swift              # Detector thresholds from Supabase
│   └── WorkoutManager.swift              # HealthKit workout tracking
└── Helpers/WatchOS10Compatibility.swift
```

## Version Information

- **Version**: 1.0.0 (`CFBundleShortVersionString`, both Info.plists)
- **Build**: 52 (`CFBundleVersion`, a literal in both Info.plists — `GENERATE_INFOPLIST_FILE = NO`,
  so `CURRENT_PROJECT_VERSION` is ignored; bump both plists in lockstep for every upload)
- **iOS Deployment Target**: 17.0
- **watchOS Deployment Target**: 10.0

## Bundle Identifiers

Unchanged by the StrokeSaver rename — they are tied to the App Store Connect record.

- **iOS App**: com.Jared.GolfTracker
- **Watch App**: com.Jared.GolfTracker.watchkitapp

## Development Team

Team ID: XMH4AVFC78

## Future Enhancement Areas

Based on the current implementation, potential areas for expansion:
- Course discovery and sharing
- Social features and leaderboards
- Advanced statistics and analytics
- Weather integration
- Shot shape analysis using motion data
- Machine learning for club recommendations
- Apple Watch complications
- Widgets for iOS 14+
- CloudKit sync for multi-device support
- Stroke gain analysis
- Handicap calculation
