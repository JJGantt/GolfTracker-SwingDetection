# Getting StrokeSaver on the App Store

Everything about submission: where it stands, how a build reaches App Store Connect, how
the store screenshots are made, and what Apple requires before review. Store copy lives in
[LISTING.md](./LISTING.md); the wider v1 work list is [V1_PUNCHLIST.md](./V1_PUNCHLIST.md).

---

## Where it stands

- **App record:** `GolfTrackerJP`, bundle `com.Jared.GolfTracker` (watch companion
  `com.Jared.GolfTracker.watchkitapp`), team `XMH4AVFC78`. It already exists on App Store
  Connect — never "create new app".
- **Version:** both Info.plists read `1.0.0 (72)` (checked 2026-09-16).
- **Uploads:** archive → export → `altool` is proven from this Mac; builds have reached
  TestFlight this way.
- **Left before submitting:** pick and upload screenshots, read the listing copy through,
  set category and review notes in App Store Connect, install a Release build on a device
  and play a round, and delete the staged screenshot data.

---

## Build and upload

1. **Bump the build number** above the last uploaded build: `CURRENT_PROJECT_VERSION`
   in the project-level build settings (not a target's). Both Info.plists read it as
   `$(CURRENT_PROJECT_VERSION)`, and `CFBundleShortVersionString` reads `$(MARKETING_VERSION)`
   the same way, so the phone and the embedded watch app cannot carry different numbers.
   A target-level value would override the project's for that target alone, so neither
   target sets one.
2. **Install the device platforms.** Xcode 26 ships without the iOS/watchOS *device*
   platforms, and archiving the embedded-watch scheme needs both. Get them from
   Xcode → Settings → Components. `xcodebuild -downloadPlatform iOS` also drags in the
   ~8.5 GB simulator runtime.
3. **Archive, then export with the App Store Connect API key.** The Xcode Apple ID
   session is expired, so automatic signing can't log in; the key mints the distribution
   certificate and App Store profile headlessly:
   `-authenticationKeyPath <AuthKey.p8>`
   `-authenticationKeyID <key id>`
   `-authenticationKeyIssuerID <issuer id> -allowProvisioningUpdates`
4. **Upload** with `xcrun altool --upload-app`.
5. **If certificate creation fails with "PLA Update available"**, only the account holder
   can clear it: accept the updated Program License Agreement at
   developer.apple.com/account, then wait about a minute for the account state to settle.

`ITSAppUsesNonExemptEncryption = false` is already in both plists, so no export-compliance
prompt appears on upload.

---

## Screenshots

**Sizes.** iPhone 6.9" is 1320×2868 (simulator "SS 6.9"); Apple Watch 46mm is 416×496
(simulator "SS Watch", paired with the phone simulator). Confirm the currently required
set in App Store Connect at upload time — Apple changes it. Uploads must carry no alpha
channel, so convert PNG to JPEG before uploading.

**How the shots are staged.** Tooling lives in the algorithms package repo, at
`StrokeSaverAlgorithms/tools/screenshots/`, with its own README (it works against the
account's own data through that repo's `swing_detection/sb.py`). The app draws everything itself: strokes and targets are written into
the round in Supabase, and the simulator's GPS is walked along the route
(`xcrun simctl location`) so the trail is recorded the way a real round records it.
`scenarios.json` holds the holes and the scenarios (tee, green, centerline, the strokes
and where they were hit from, the walk, where the player ends up, the target).

**Traps, each of which cost an afternoon:**

- **The watch simulator gets its map tiles through the paired phone simulator.** When that
  link dies (it dies under memory pressure), the watch draws MapKit's grey placeholder for
  any area not already cached and shows a red "iPhone disconnected" status icon, while
  `xcrun simctl list pairs` still reports "connected". The watch's log
  (`log show --predicate 'subsystem BEGINSWITH "com.apple.GeoServices"'`) says
  `Paired device finished request without sending information for tile`. Rebooting the two
  simulators clears the icon but not the tiles. What fixes both: `xcrun simctl shutdown all`,
  `killall -9 com.apple.CoreSimulator.CoreSimulatorService`, then boot both again.
  `stage_watch.py` checks the map before walking and does this by itself.
- **Only the device that starts a round records its trail**, and relaunching mid-round
  doesn't resume recording. Start the round on the device being shot.
- **A course with no elevation cells shows a dash beside every yardage** (the elevation
  readout has no solution). Disney's Palm has none; Hyde Park has about 5,900.
- **The watch fades its + button on a hole marked finished**, which reads as disabled in a
  screenshot. The staging scripts clear the round's finished holes.
- **Near-green positions put the watch into its on-green readout**, which doesn't show the
  app off. Shoot drives, layups and tee shots instead.
- **The phone's in-round map frames tee → pin**, so the shots already hit, their distances
  and the trail stay on screen.
- **Set the status bar** before shooting: `xcrun simctl status_bar <phone> override --time
  "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`.
  Restarting the simulator service clears the override.

**Current set (2026-09-16):** 18 iPhone and 18 Apple Watch in-round shots staged on
Disney's Palm (drives, layups and carry-the-water tee shots across holes 1, 6, 9, 10, 13,
14, 16, 18), plus the approved stats screens. Not yet chosen, converted or uploaded, and
the staged rounds are still in the database until the set is approved — then
`unstage_rounds.py` deletes them.

---

## Listing

Copy, keywords and promotional text: [LISTING.md](./LISTING.md).

- **Category:** Sports (primary), Health & Fitness (secondary).
- **Age rating:** 4+.
- **Review notes:** optional, and they speed review. Explain how to see swing detection
  without a golf course.
- **Marketing URL:** optional; the support URL works.
- **Demo account:** Sign in with Apple only, so there is no password to hand over. Say so
  in the review notes.

---

## Apple's requirements

### In place

- **Privacy manifests** — `PrivacyInfo.xcprivacy` in both targets, registered in the
  pbxproj and verified inside both `.app` bundles. Declares precise and coarse location,
  round content, device id (iOS), plus HealthKit workouts and motion diagnostics (watch),
  none used for tracking; `UserDefaults` declared with reason `CA92.1`.
- **Export compliance** — `ITSAppUsesNonExemptEncryption = false` in both plists.
- **Privacy policy** — https://jjgantt.github.io/golftracker-site/privacy.html
- **Support page** — https://jjgantt.github.io/golftracker-site/support.html
  (contact `jared.gantt+golftracker@gmail.com`).
- **Bundle metadata** — version and build literals, `CFBundleIconName`, full icon sets on
  both targets, blank launch screen, iOS locked to portrait.
- **Usage strings** — location when-in-use and always (iOS), motion and HealthKit (watch).
- **Account deletion** — Settings → Delete My Data removes the account's rows and signs
  out. Required because the app has Sign in with Apple.
- **Round data in Supabase** — rounds, holes, strokes and targets all sync; the server is
  the source of truth for both devices.
- **Permission-denied guidance** — location banner on the Play tab, HealthKit banner on
  the watch home screen, motion denial view on the watch.
- **First-run permission primers** — one per platform.
- **Deployment targets** — iOS 17.0 / watchOS 10.0, with `#available(watchOS 11.0, *)`
  gates where newer APIs are used.

### Outstanding

- [ ] **Screenshots** uploaded (see above).
- [~] **Listing copy** read through before pasting into App Store Connect.
- [ ] **Category** and **review notes** set in App Store Connect.
- [~] **Release-configuration smoke test** — both targets build clean in Release; still
  owed: install on a device and play a round.
- [ ] **Staged screenshot data deleted** once the set is approved.

### Deferred past v1

- **Accessibility pass** — VoiceOver labels on icon-only buttons, Dynamic Type at the
  largest sizes, a check for hardcoded light/dark colours. Not a review blocker.
- **Crash reporting** — Xcode Organizer covers it for now.
- **TestFlight external beta**, complications, widgets, Siri shortcuts, richer haptics.

---

## References

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files)
- [Required Reason API list](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api)
- [App Store Connect Help](https://developer.apple.com/help/app-store-connect/)
