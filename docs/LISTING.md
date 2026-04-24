# App Store Listing Copy

Drafts for every field App Store Connect will ask for. Paste when you create the app record and fill the listing. Review / edit all of this before submitting — it's a first cut.

---

## Creating the app record

1. Go to https://appstoreconnect.apple.com → **My Apps** → `+` → **New App**.
2. Fill in:
   - **Platform:** iOS (Watch app ships as part of the iOS app — no separate record needed)
   - **Name:** GolfTracker
   - **Primary Language:** English (U.S.)
   - **Bundle ID:** `com.Jared.GolfTracker` (dropdown of registered App IDs)
   - **SKU:** `golftracker-ios` (internal, any string, never shown to users)
   - **User Access:** Full Access

That creates the record. Everything below goes into the **App Information** and **Version Information** sections.

---

## App Information

- **Category — Primary:** Sports
- **Category — Secondary:** Health & Fitness
- **Content Rights:** "No, it does not contain, show, or access third-party content"
- **Age Rating:** Launch the questionnaire. Answer "None" to every category (no violence, no drugs, no gambling, no profanity, etc.). Result: **4+**.
- **Privacy Policy URL:** https://jjgantt.github.io/golftracker-site/privacy.html

---

## Version Information

### App Name (30 char max)

```
GolfTracker
```

### Subtitle (30 char max)

```
GPS, scoring & swing detection
```

### Promotional Text (170 char max — editable without new build)

```
Track every shot of every round. Precise GPS distances, automatic swing detection on Apple Watch, and a live scorecard that syncs between your devices.
```

### Description (4000 char max)

```
Track every shot of every round — from tee to green — with shot-by-shot GPS, automatic swing detection, and a full digital scorecard. GolfTracker is built for iPhone and Apple Watch, with a focus on what actually matters during a round.

GPS distances, always
Get precise distances to the pin on every hole. The map rotates with your heading, zooms as you approach the green, and drops the hole marker exactly where it needs to be.

Automatic swing detection
GolfTracker records each shot from your wrist. Motion data is analyzed in real time on Apple Watch to identify full swings and putts, log your location, and add the shot to your scorecard — no tapping required.

Live scorecard
Track pars, strokes, and penalties as you play. Your round syncs between iPhone and Apple Watch so you can check your card from either device without missing a beat.

Map your own courses
Play any course, not just the famous ones. Add a hole by standing on the green and tapping once. Move pins, set pars, and your course is saved.

Club stats that get smarter
Every recorded shot feeds a distance profile for each club. See your actual carry distances, by club, across every round you play.

Built for Apple Watch
A Watch-first round view — large distance readout, Digital Crown club picker, and haptic feedback on every recorded shot. Keep your phone in your bag.

Your data, your account
Sign in with Apple. Your round history follows you across devices and reinstalls. Delete your data any time from Settings — Apple's privacy standard, end to end.
```

Character count: ~1700. Room to grow if needed.

### Keywords (100 char max, comma-separated)

```
golf,gps,rangefinder,scorecard,distance,swing,watch,stats,course,handicap,tracker,yards
```

87 chars. Commas count, spaces also count (none used here intentionally).

### Support URL

```
https://jjgantt.github.io/golftracker-site/support.html
```

### Marketing URL (optional)

Leave blank, or point at `https://jjgantt.github.io/golftracker-site/` (the landing page).

### Copyright

```
© 2026 Jared Gantt
```

### Version

```
0.9.0
```

(Matches `CFBundleShortVersionString` in Info.plist. Increment in Xcode when you change the version for a release.)

---

## Review notes (optional but speeds review)

Apple's reviewer reads this. Short note explaining how to exercise the app.

```
GolfTracker uses Apple Sign In for authentication. Motion-based swing detection requires the Apple Watch. To test:
1. Sign in with any Apple ID.
2. Grant Location, Motion, and HealthKit permissions when prompted.
3. On iPhone, tap "Manage Clubs" to see the default club set, then go to the Courses tab to create a course.
4. Start a round — the iPhone shows a live map; the Apple Watch app mirrors distances and records detected swings.

No demo account needed. Data deletion is available in Settings (gear icon, top-right of Home).
```

### Contact Information

- **First Name / Last Name:** Jared Gantt
- **Phone:** _(your number)_
- **Email:** jared.gantt+golftracker@gmail.com

### Demo Account

Not applicable — Apple Sign In, no password-based accounts.

---

## Screenshots

Required sizes for 2026 submission (per Apple):

- **6.9" iPhone** (iPhone 16 Pro Max / iPhone 17 Pro Max) — **1320 × 2868 px** — required
- **6.5" iPhone** (iPhone 11 Pro Max / iPhone XS Max) — **1242 × 2688 px** — required
- **Apple Watch** — Series 10 (46mm) — **476 × 600 px** — required for Watch apps

Minimum 3 per size, maximum 10. Aim for 5 that tell the product story.

### Suggested shot list

iPhone:
1. Active round map — distance readout, hole marker visible
2. Live scorecard view — mid-round, some holes played
3. Stats dashboard — club distance distributions
4. Home screen — clean first-impression, Manage Clubs + gear icon visible
5. Course editor — dropping pins on a hole

Apple Watch:
1. Round view with big distance readout
2. Club picker (Digital Crown)
3. Stroke-recorded haptic / confirmation state
4. Scorecard on the watch
5. Home screen

### How to capture

- **Simulator:** `Device → Screenshot` (⌘S) while running the relevant sim. Exports to Desktop at the exact required pixel size.
- **Real device:** physical screenshot buttons, AirDrop to Mac. iPhone 16 Pro Max and iPhone 11 Pro Max both available as simulators in current Xcode, so simulators alone cover it.

For the Watch simulator: `Device → Screenshot` → exports at 410×502 (Series 10) which App Store Connect accepts because it auto-scales — but to be safe, run the Series 10 46mm simulator specifically.

---

## Pricing

- **Price:** Free (or pick a tier from the dropdown)
- **Availability:** All countries/regions by default

---

## What's New in This Version (for version 0.9.0)

```
First public release.
```

For subsequent versions, use bullet-style release notes — "Fixed X. Improved Y. Added Z."
