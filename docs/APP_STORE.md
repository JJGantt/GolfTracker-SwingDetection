# App Store Submission Checklist

Living checklist for GolfTracker's path to the App Store. Check items off as they land. Add new rows as gaps surface.

Legend: `[ ]` not started · `[~]` in progress / partial · `[x]` done · `[?]` needs confirmation

---

## Must-Have — Apple will reject without these

### Privacy & compliance
- [x] **PrivacyInfo.xcprivacy manifest** — created for both targets (2026-04-23) and registered in pbxproj. Both ship in their respective .app bundles (verified against Debug build output).
- [x] **Export-compliance key** — `ITSAppUsesNonExemptEncryption = false` added to both Info.plists (2026-04-23).
- [x] **Privacy Policy URL** — https://jjgantt.github.io/golftracker-site/privacy.html (2026-04-23).

### Bundle metadata
- [x] **Version / build** — set to `CFBundleShortVersionString = 0.9.0`, `CFBundleVersion = 1` in both Info.plists (2026-04-23). Pre-release framing for TestFlight-first path; bump `CFBundleVersion` every upload, promote to `1.0.0` at public launch.
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

### Backend data pipeline (v1 blocker)
- [ ] **Full round data → Supabase** — currently only motion slices upload via `SupabaseUploader`. Round-level data (courses, holes, strokes, targets, scores) still lives only in local JSON. Wire up upload on every mutation so Supabase is the source of truth. Keyed to the same per-install device UUID.
- [x] **In-app "Delete my data" button** — `SettingsView` (opens from gear icon on `HomeView`) has "Delete My Data" with confirmation. Calls `SupabaseSync.deleteAllUserData()` → parallel DELETEs on `rounds`, `courses`, `club_sets`, `clubs`, `club_types` scoped to `user_id`; CASCADE handles children. Motion data (device-id keyed) untouched. Signs out on completion.

### App Store Connect side
- [x] **Support URL** — https://jjgantt.github.io/golftracker-site/support.html (2026-04-23).
- [ ] **Marketing URL** (optional) — can be same as Support URL.
- [ ] **Screenshots** — iPhone (6.7", 6.5", 5.5" display sizes) + Apple Watch (all series currently shipping). Min 1 screenshot per device size; typical is 3-5. Use TestFlight build for fresh captures.
- [~] **App description + keywords** — drafted in [LISTING.md](./LISTING.md). Review before pasting into App Store Connect.
- [ ] **Age rating** — run through the questionnaire. GolfTracker has no objectionable content; will land at 4+.
- [ ] **Category** — "Sports" (primary), "Health & Fitness" (secondary).
- [ ] **Review notes** — brief note to reviewer explaining how to test (e.g., "Enable motion permission, tap Motion Test from Watch home to see the detection UI"). Not required but speeds up review.
- [ ] **Demo account** — not applicable, no login.

### Deployment targets
- [x] **Deployment targets** — locked in at iOS 17.0 / watchOS 10.0 (2026-04-23). CLAUDE.md updated to match Info.plists. `#available(watchOS 11.0, *)` gates verified in `WatchOS10Compatibility.swift` + `ActiveRoundView.swift` — genuine watchOS 10 compatibility.

---

## Strongly Recommended — code quality before launch

### Build hygiene
- [ ] **Release build smoke test** — run `xcodebuild -configuration Release` end-to-end. `#if DEBUG`-gated `dprint` calls behave differently; verify nothing in release console spam or missing logs that you actually need.
- [ ] **Archive builds cleanly** — from Xcode, `Product > Archive` must succeed for both targets. This is what you upload to App Store Connect.

### User experience
- [x] **Permission-denied UX** (2026-04-23; location banner re-homed 2026-07-31)
  - [x] Motion: `MotionAuthDeniedView` (pre-existing).
  - [x] Location: `LocationPermissionBanner` (iOS) on the **Play tab** (`PlayTabView`) — observes `LocationManager.authorizationStatus`, deep-links to Settings. It was mounted on `HomeView`, which was deleted when the tab bar became Stats/Play/History/Settings; the banner was therefore **unreachable** and a location-denied user got no guidance at all (Start Round just fell through to the course-name prompt). Now on the screen that actually needs location.
  - [x] HealthKit: `HealthKitBanner` (Watch) on `WatchHomeView` — observes `WorkoutManager.healthKitAuthorizationStatus`, instructs user to re-enable via iPhone Watch app.
- [x] **First-run onboarding** — permissions primer implemented 2026-04-23. iOS `OnboardingView` primes Location; Watch `WatchOnboardingView` primes Motion + HealthKit. Each primer fires the system prompt inline; deep-links to Settings if previously denied. Gated by `@AppStorage("hasSeenOnboarding")` (iOS) and `@AppStorage("hasSeenWatchOnboarding")` (Watch). Empty state / "Create your first course" CTA deferred — not in v1 scope.
- [~] **Crash-mid-round recovery** — skipped for v1 (2026-04-23). Audit confirmed every mutation in `DataStore` / `WatchDataStore` calls `saveRounds()` / `saveRound()`; no visible gaps. Rounds will also be backed by Supabase once the round-data pipeline lands.
- [~] **Data-model migration safety** — skipped (2026-04-23). Nothing shipped yet, no production data to migrate.

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

- [x] **Apple Developer Program enrollment** — enrolled.
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

## Plans

Per-item execution plans. As items complete, replace the plan body with a **Done:** summary of what actually shipped.

### PrivacyInfo.xcprivacy manifests
**Done (2026-04-23):** Created `GolfTracker/PrivacyInfo.xcprivacy` and `GolfWatch Watch App/PrivacyInfo.xcprivacy` and registered them in `GolfTracker.xcodeproj/project.pbxproj` (PBXFileReference + PBXBuildFile + PBXGroup + PBXResourcesBuildPhase for each target).

Declared collected data types (all linked to user via anonymous per-install UUID, **not** used for tracking):
- iOS: precise location, coarse location, other user content (rounds/strokes/courses), device ID
- Watch: + fitness (HealthKit workouts), other diagnostic data (motion slices)

Declared accessed-API reasons: `UserDefaults` → `CA92.1` on both targets. Audit confirmed no other required-reason APIs are hit (no file timestamps, no systemUptime, no disk-space reads).

Verified against `xcodebuild build` output — both manifests land inside their `.app` bundles.

### ITSAppUsesNonExemptEncryption
**Done (2026-04-23):** Added `ITSAppUsesNonExemptEncryption=false` to `GolfTracker/Info.plist` and `GolfWatch Watch App/Info.plist`. App Store Connect will no longer prompt for export compliance on upload.

### Privacy Policy + Support URLs
**Done (2026-04-23):** Repo `JJGantt/golftracker-site` created and deployed via GitHub Pages.
- Privacy: https://jjgantt.github.io/golftracker-site/privacy.html
- Support: https://jjgantt.github.io/golftracker-site/support.html
- Contact email: `jared.gantt+golftracker@gmail.com` (Gmail plus-tag; can swap to a dedicated alias later).
- Deletion handled in-app via `Settings → Delete my data` (see the in-app delete button v1 blocker).
- Content scope: location (precise + coarse), motion, HealthKit permission (called out as required for 800 Hz raw accel), round content, anonymous device UUID. Backend referenced generically — no vendor name published.

### Version / build bump
**Done (2026-04-23):** Both Info.plists set to `0.9.0 (1)`. Pre-release for TestFlight. `CFBundleVersion` must increment every App Store Connect upload; promote version string to `1.0.0` at public launch.

### Deployment target alignment
**Done (2026-04-23):** Kept iOS 17.0 / watchOS 10.0 (Info.plist values). Updated CLAUDE.md's stale "watchOS 26.0" claim. Confirmed `#available(watchOS 11.0, *)` gates in `WatchOS10Compatibility.swift` and `ActiveRoundView.swift` keep the app genuinely compatible with watchOS 10 — nothing to rip out.

### Release build smoke test
**Submission-time step.** When ready to upload: `Product > Archive` from Xcode for both targets, fix any warnings, install on device, play through a round. Debug builds passed throughout development.

### Permission-denied UX
**Done (2026-04-23):**
- iOS: added `GolfTracker/Views/Shared/PermissionBanner.swift` with a reusable `PermissionBanner` and a `LocationPermissionBanner` wrapper that observes `LocationManager.authorizationStatus`. Mounted on `HomeView`. On `.denied`/`.restricted` shows a banner with an "Open Settings" button that deep-links via `UIApplication.openSettingsURLString`.
- Watch: added `GolfWatch Watch App/Views/Components/HealthKitBanner.swift`. Extended `WorkoutManager` with `@Published healthKitAuthorizationStatus` and `refreshAuthorizationStatus()` (called on init + after `requestAuthorization`). Banner mounted on `WatchHomeView`; on `.sharingDenied` tells the user to re-enable HealthKit via the iPhone Watch app (no watchOS Settings deep-link exists).
- Motion denial (`MotionAuthDeniedView`) was already in place.
- Both new files registered in `project.pbxproj` (PBXFileReference + PBXBuildFile + PBXGroup + Sources build phase for their target). iOS build verified.

### First-run onboarding
**Done (2026-04-23):** Scope scoped down to a single permissions primer per platform — no welcome or "first course" screens.
- iOS: `GolfTracker/Views/OnboardingView.swift`, gated by `@AppStorage("hasSeenOnboarding")` on `ContentView`, shown as `.fullScreenCover`. Primes Location with rationale; first tap fires `LocationManager.requestPermission()`, subsequent taps (after denial) deep-link to `UIApplication.openSettingsURLString`.
- Watch: `GolfWatch Watch App/Views/WatchOnboardingView.swift`, gated by `@AppStorage("hasSeenWatchOnboarding")` in `GolfWatchApp`. Primes Motion + HealthKit stacked. Motion calls `SwingDetectionManager.checkAndRequestMotionAuthorization()`; HealthKit calls `WorkoutManager.requestAuthorization`. Status reflects live from the managers' published auth state.
- Empty state / "Create your first course" CTA and dev-reset toggle intentionally deferred.

### Crash-mid-round recovery
**Skipped for v1 (2026-04-23):** Audit found save coverage is already good — every mutation method in `DataStore` (iOS) and `WatchDataStore` (Watch) calls `saveRounds()`/`saveRound()`. Real server-side backup arrives with the Supabase round-data pipeline. Low risk, not a review blocker.

### Data-model migration safety
**Skipped (2026-04-23):** Nothing has shipped; no production data to migrate.

### Accessibility pass
**Deferred past v1 (2026-04-23).** Not a review blocker; revisit post-launch. Scope when picked back up: VoiceOver labels on icon-only buttons, Dynamic Type XXXL sweep, grep for hardcoded `Color.white`/`.black` + Dark Mode check.

### TestFlight beta
After must-haves land: archive, upload to App Store Connect, internal testers first, then 5–10 external golfers. Short "what to test" note focusing on swing-detection accuracy across player styles. Feedback via Google Form linked from the TestFlight note.

### Supabase round-data pipeline (v1 blocker)
**Done (2026-04-23):**
- **Auth:** Sign in with Apple entitlement added. `SupabaseClient` + `AuthManager` (Keychain-backed session) + `LoginView` (native SIWA button). `ContentView` gates the app on auth → onboarding → tabs.
- **Schema:** `supabase/migrations/00007_round_data.sql` applied via `supabase db push`. 10 normalized tables (`club_types`, `clubs`, `club_sets`, `club_set_type_selections`, `courses`, `holes`, `rounds`, `round_holes`, `strokes`, `targets`), all with RLS policies enforcing `user_id = auth.uid()` (child tables verify via parent). Rounds survive course deletion via `ON DELETE SET NULL`. Strokes' `club_id` is a plain UUID, not FK, so deleting a club doesn't wipe historical strokes.
- **Sync:** `SupabaseSync` manager mirrors every mutation as a REST upsert/delete with `Bearer <user access token>`. Failed requests queue on disk (`supabase_sync_queue.json`), drained on launch + via a 30-s timer. Wired into every `DataStore` save + delete method (courses, holes, clubs, club types, club sets, rounds, strokes, targets).
- **Upload-only (no pull-on-launch) for v1.** Two-way sync revisits when there's a real multi-device/reinstall story post-launch.
- **Motion data stays separate:** `swing_events` + storage CSVs keep device-id keying; never linked to auth user. Anonymous research data, not subject to deletion.
- **Privacy policy updated** to disclose Apple Sign In and the two-tier deletion model; pushed to GitHub Pages.

### External assets
- Apple Developer Program enrollment ($99).
- App Store Connect app record (bundle ID `com.Jared.GolfTracker`).
- Xcode auto-managed signing; verify provisioning before archive.
- Screenshots: iPhone 15 Pro Max sim (6.7"), iPhone 8 Plus sim (5.5"), Apple Watch Series 10 sim. 3–5 per size: home, active round map, scorecard, stats, watch play view.
- 4000-char description + 100-char keyword list.

---

**Last updated:** 2026-07-31. Update the date and any relevant rows when items land or change status.
