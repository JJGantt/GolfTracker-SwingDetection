# App Store Listing — StrokeSaver

**Live in App Store Connect as of 2026-07-31.** This file mirrors what's actually
pushed; edit here and re-push, don't let them drift.

App record: `GolfTrackerJP` internally, **`StrokeSaver`** on the store (`GolfTracker` and
`Golf Tracker` are both taken). Bundle `com.Jared.GolfTracker`, app id 6756589450.

| Field | Value |
|---|---|
| App name | StrokeSaver |
| Subtitle | GPS, scoring & swing detection |
| Age rating | 4+ (`userGeneratedContent: false` — valid because user-typed course names are scoped to their creator; see S6/UGC in V1_PUNCHLIST) |
| Categories | Sports (primary), Health & Fitness (secondary) |
| Privacy policy | https://jjgantt.github.io/golftracker-site/privacy.html |
| Support URL | https://jjgantt.github.io/golftracker-site/support.html |
| Marketing URL | https://jjgantt.github.io/golftracker-site/ |
| Copyright | 2026 Jared Gantt |
| Version | 1.0.0 (build 49) |

## Keywords (100 max)

```
golf,gps,rangefinder,scorecard,distance,swing,watch,stats,course,handicap,tracker,yards
```

## Promotional text (170 max)

```
Track every shot of every round. Precise GPS distances, automatic swing detection on Apple Watch, and a live scorecard that syncs between your devices.
```

## Description (4000 max — currently 3030)

```
Every shot of every round, logged from your wrist.

StrokeSaver records your golf automatically. Swing, and the shot goes on your card with its GPS position and the club you used. No tapping between shots. No pulling your phone out of the bag.


DISTANCE TO THE PIN

A large, always-visible yardage that updates as you walk. The map turns with you, the pin stays ahead, and the number is there before you've picked a club. Everything a rangefinder gives you, without taking it out or holding it steady.


PLAYS-LIKE YARDAGE

An uphill 150 is not a 150. StrokeSaver adjusts for elevation, and the club it suggests knows the difference. Tap to switch between measured and plays-like.


MEASURE TO ANYTHING

Drop a target on the carry over water, the front bunker, the corner of the dogleg. Live yardage to any point you choose, for as long as you want it.


IT KNOWS A REAL SWING FROM A PRACTICE ONE

Motion sensors on Apple Watch read every movement of your wrist, and only the shots that count reach your card. Waggles and rehearsals are filtered out, so you are not deleting phantom strokes at the end of the hole.


AND IT COUNTS YOUR PUTTS

A putting stroke is a fraction of the motion of a full swing, which is why most apps ignore putts entirely and make you tap them in. StrokeSaver reads them at high resolution and tells them apart from full swings, so your putts per round and putts per hole are counted, not estimated.


WHERE YOU AIMED, WHERE IT WENT

StrokeSaver reads the direction of your swing from the motion of your wrist and compares it to where the ball finished. See how far off line each shot was, in degrees, and whether you miss the same way every time.


YOUR PREVIOUS ROUNDS, GHOSTED UNDER THIS ONE

Turn on the history overlay and your previous rounds at this course appear faintly beneath you on the same hole. The walk you took, the shots you hit, labelled with distances.


YOUR CLUB DISTANCES, MEASURED

Not the numbers you wish you hit. Each shot's distance comes from the ground you cover between it and your next one, so every club builds a real distance profile, shown with the sample size behind it.


A CARD THAT KEEPS UP

Strokes and putts land on your card as they happen. Add a penalty with a tap where it happened. Everything syncs between iPhone and Apple Watch, so you can check the card from either one.


ANY COURSE, INCLUDING YOURS

Play the municipal nobody has mapped. StrokeSaver finds course layouts automatically where they exist, and where they don't you drop a pin on the green and it remembers. Name it once and it's yours from then on.


HOLE BY HOLE, ROUND AFTER ROUND

See which holes actually cost you strokes at each course you play, how far over par they run, and how many putts you leave there.


BUILT FOR THE WATCH

A large distance readout, Digital Crown club selection, and a haptic on every shot recorded. Keep the phone in the bag.


PRIVATE BY DEFAULT

Sign in with Apple. Your rounds follow you across devices. Delete everything from Settings whenever you want.
```

## Copy rules that shaped this

- **Nothing that hasn't shipped.** Multiplayer is deliberately absent: it is code-complete
  but has never been run by two people.
- **No hedging.** An earlier draft said the slope data "gets better the more it's played",
  which implies it starts bad. Cut.
- **Don't explain the system.** The plays-like section briefly described the barometer and
  the shared height map. Users don't need the mechanism, they need the benefit.
- **Don't overclaim timing.** The opening says a shot lands on the card with its position
  and club, NOT its distance — distance isn't known until the next shot is recorded.
- **Penalties are manual.** Strokes and putts are automatic; penalties are tapped in.
- No em-dashes.

## Still outstanding

**Screenshots — the only remaining blocker.** Required: 6.9" iPhone (1320x2868), 6.5"
iPhone (1242x2688), Apple Watch. Minimum 3 per size.

Capture from Jared's device, not a fresh install: elevation and the ghost overlay only
render on courses with existing history, so a clean install shows neither.
