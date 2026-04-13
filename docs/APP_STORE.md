# App Store Submission Checklist

Living checklist for GolfTracker's path to the App Store. Check items off as they land. Add new rows as gaps surface.

Legend: `[ ]` not started · `[~]` in progress / partial · `[x]` done · `[?]` needs confirmation

---

## Must-Have — Apple will reject without these

### Privacy & compliance
- [ ] **PrivacyInfo.xcprivacy manifest** — not present in repo (verified `find` 2026-04-13). Required since 2024 for apps using CoreLocation, CoreMotion, HealthKit, UserDefaults, system boot time, file timestamps, disk space. Needs one per target: `GolfTracker/PrivacyInfo.xcprivacy` + `GolfWatch Watch App/PrivacyInfo.xcprivacy`. Declare `NSPrivacyCollectedDataTypes` (location type + coarse/precise), `NSPrivacyAccessedAPITypes` (`CA92.1` for UserDefaults, others for file timestamps etc.). Apple's template: https://developer.apple.com/documentation/bundleresources/privacy_manifest_files.
- [ ] **Export-compliance key** — add `ITSAppUsesNonExemptEncryption = false` to both Info.plists (we don't ship custom crypto). Skipping this prompts the question in App Store Connect every release.
- [ ] **Privacy Policy URL** — public HTTPS page describing what data the app collects (location, motion, HealthKit). Required field in App Store Connect. Can be a single page.

### Bundle metadata
- [~] **Version / build** — currently `CFBundleShortVersionString = 1.0` and `CFBundleVersion = 1` in both Info.plists. Bump to something intentional before first submission (e.g. `0.9.0` pre-release or `1.0.0` for first public). Build number must increment every upload.
- [?] **Bundle IDs** — declared in CLAUDE.md as `com.Jared.GolfTracker` + `com.Jared.GolfTracker.watchkitapp`. Needs matching App IDs + provisioning profiles in App Store Connect.
- [x] **CFBundleIconName** — `AppIcon` set in iOS Info.plist.
- [x] **App icons** — both targets have `AppIcon.appiconset` with full size set (iOS: 20/29/40/60 @2x@3x + 1024; Watch: all complication/corner/circular sizes + 1024).

### Launch / UI infra
- [x] **iOS launch screen** — `UILaunchScreen = {}` in Info.plist (blank screen, valid for iOS 13+). If we want a branded launch, replace empty dict with `UIImageName` entry pointing at an asset.
- [x] **Supported orientations** — iOS locked to `UIInterfaceOrientationPortrait`.

### Usage descriptions (already in place)
- [x] `NSLocationWhenInUseUsageDescription` (iOS) — "GolfTracker needs your location to calculate distances to holes and track your shots during a round."
- [x] `NSLocationAlwaysAndWhenInUseUsageDescription` (iOS) — same copy. Consider differentiating: "...during a round even when the app is in the background."
- [x] `NSMotionUsageDescription` (Watch) — per CLAUDE.md.
- [x] `NSHealthShareUsageDescription` + `NSHealthUpdateUsageDescription` (Watch) — per CLAUDE.md.

### App Store Connect side
- [ ] **Support URL** — public HTTPS page with contact info (email form is enough). Cheapest path: GitHub Pages single `index.html`.
- [ ] **Marketing URL** (optional) — can be same as Support URL.
- [ ] **Screenshots** — iPhone (6.7", 6.5", 5.5" display sizes) + Apple Watch (all series currently shipping). Min 1 screenshot per device size; typical is 3-5. Use TestFlight build for fresh captures.
- [ ] **App description + keywords** — 4000-char description, 100-char keyword list.
- [ ] **Age rating** — run through the questionnaire. GolfTracker has no objectionable content; will land at 4+.
- [ ] **Category** — "Sports" (primary), "Health & Fitness" (secondary).
- [ ] **Review notes** — brief note to reviewer explaining how to test (e.g., "Enable motion permission, tap Motion Test from Watch home to see the detection UI"). Not required but speeds up review.
- [ ] **Demo account** — not applicable, no login.

### Deployment targets
- [~] **Deployment targets** — currently `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, `WATCHOS_DEPLOYMENT_TARGET = 10.0`. CLAUDE.md claims watchOS 26.0 — mismatch, pick one. Lower target = wider audience; higher target = access to newer APIs (we're using `digitalCrownRotation(sensitivity:)` which is watchOS 11+, gated via `#available` in `WatchOS10Compatibility.swift`).

---

## Strongly Recommended — code quality before launch

### Build hygiene
- [ ] **Release build smoke test** — run `xcodebuild -configuration Release` end-to-end. `#if DEBUG`-gated `dprint` calls behave differently; verify nothing in release console spam or missing logs that you actually need.
- [ ] **Archive builds cleanly** — from Xcode, `Product > Archive` must succeed for both targets. This is what you upload to App Store Connect.

### User experience
- [ ] **Permission-denied UX** — what does the user see if they tap "Don't Allow" for Location / Motion / HealthKit?
  - [x] Motion: `MotionAuthDeniedView` exists and is shown when `checkAndRequestMotionAuthorization` returns denied/restricted.
  - [ ] Location: verify `LocationManager` surfaces a denied state and the UI shows something helpful (not just a silent "no distance").
  - [ ] HealthKit: similar — app shouldn't break if user denies workout tracking; it should just not log a workout.
- [ ] **First-run onboarding** — what does a brand-new user see when they open the app? Empty courses list with a "Create your first course" affordance? Priming screen explaining why we need permissions? Currently untested for the cold-start path.
- [ ] **Crash-mid-round recovery** — force-quit the app mid-round on device; re-open; verify the round resumes. Round data is saved to JSON in Documents, but `saveRound()` may not be called on every state change.
- [ ] **Data-model migration safety** — we just removed `landingLatitude`/`landingLongitude`/`acceleration` from `Stroke` in commit `94e777d`. Swift's default `Codable` ignores unknown keys, so old saved rounds should decode, but test with an actual pre-change JSON file on device.

### Accessibility
- [ ] **VoiceOver labels** on critical buttons (record stroke, undo, aim direction, penalty). Currently buttons are icons only, so labels are inferred — verify they read sensibly.
- [ ] **Dynamic Type** — text scaling in Settings > Display & Brightness > Text Size. Watch cares less; iPhone screens must not overflow at largest size.
- [ ] **Dark Mode** — the app uses system colors by default. Verify no hardcoded light/dark-only colors.

### Privacy & data
- [?] **Data export** — not required, but if we ever collect analytics, users can ask for their data. Currently all data is local, so a zero-effort compliance statement.
- [?] **Data deletion** — App Store requires a "delete account" path if the app has accounts. N/A for GolfTracker (no accounts).

---

## Nice-to-Have — post-launch or optional polish

- [ ] **TestFlight external beta** — invite 5-10 golfers before public launch. Real-world sensor data will surface detection-tuning issues you won't find on the range.
- [ ] **Crash reporting** — Sentry, Bugsnag, or Apple's own Xcode Organizer crash reports. Xcode Organizer is free + built-in; Sentry gives richer context.
- [ ] **Analytics** — optional. Not collecting any today; if added, declare in PrivacyInfo manifest.
- [ ] **iCloud / CloudKit sync** — multi-device round history. Significant scope; post-launch.
- [ ] **Apple Watch complications** — distance-to-hole on the watch face. Requires `ClockKit` or WidgetKit setup.
- [ ] **iOS widgets** — round-in-progress widget, course quick-stats.
- [ ] **Siri Shortcuts** — "Start a round at [course]", "Record a stroke".
- [ ] **Haptic richness** — currently uses `.click` / `.notification`; could differentiate putt vs swing vs penalty.
- [ ] **StoreKit in-app purchase** — if monetizing later (pro features, course pack).

---

## External assets needed

Stuff that lives outside the repo but blocks submission:

- [ ] **Apple Developer Program enrollment** — $99/year, required to submit.
- [ ] **App Store Connect app record** — create the listing entry.
- [ ] **Certificates + provisioning profiles** — Xcode can auto-manage, but verify before archive.
- [ ] **Privacy policy page** (live HTTPS URL).
- [ ] **Support page** (live HTTPS URL, can be same host as privacy policy).
- [ ] **Marketing assets** — icon renders, screenshots, promotional text.

---

## References

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Privacy Manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files)
- [Required Reason API list](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api)
- [App Store Connect Help](https://developer.apple.com/help/app-store-connect/)

---

**Last updated:** 2026-04-13 (initial seed). Update the date and any relevant rows when items land or change status.
