# GolfTracker Vision

This document captures long-term product thinking and algorithmic ideas that should inform every feature decision. Read this before adding new features.

---

## North Star: Zero-Interaction Data Collection

**The ultimate goal is that the user could complete an entire round without ever touching the app, and still accumulate all the data we want.**

This means:
- Strokes are detected automatically (swing detection)
- The current hole is identified automatically (hole detection + aim direction)
- The club used is predicted automatically (distance-based and pattern-based prediction)
- Shot direction is inferred automatically (swing direction vector from motion)
- Everything syncs silently in the background

Every feature should be evaluated against this goal. If a feature requires user input, ask: *could this be automated?* If yes, build toward automation. If not, make the manual step as fast and frictionless as possible (one tap, pre-filled defaults, etc.).

This is aspirational — manual fallbacks are always needed. But it's the design target.

---

## Auto Aim Direction

### Problem

Right now the user manually sets an aim direction when they're not shooting toward the hole. We need an algorithmic solution that derives aim direction from motion data.

### Algorithm Concept

**Immediate (per-shot):** Use the swing direction vector (see SWING_DETECTION.md) to derive the magnetic heading of the forward stroke at peak acceleration. This gives the direction of the shot automatically from the motion data. No user input needed.

**Population-level (course mapping):** Over many rounds, accumulate shots where we're confident the player was aiming at the hole:
- Filter: player is within a distance where a straight line to the hole is very likely (e.g., < 150 yards for approach shots, < 30 yards for chips)
- Filter: the detected aim direction is within a small angular tolerance of the GPS bearing to the hole
- These shots form a clean training set for validating auto-aim accuracy

For longer shots (> 300 yards), the player may be intentionally aiming at a bend in the fairway rather than the hole. This is the ambiguous case. The auto-aim algorithm should flag high uncertainty on these shots rather than guessing.

**Fairway shape learning (long-term):** If we accumulate enough shots at the same hole across many rounds, the distribution of aim directions at various yardages maps the actual fairway routing. This could auto-generate a "recommended aim" overlay on the map.

### How It Enables Auto Hole Selection

Currently the user manually selects which hole they're playing. Combining aim direction with GPS position can automate this:

1. At each swing, compute the GPS bearing and distance to every hole on the course
2. The detected aim direction (from motion) narrows down which hole is likely being targeted
3. Score each hole: `score = GPS_bearing_match + distance_plausibility + hole_order_prior`
4. The highest-scoring hole becomes the auto-selected current hole

The "hole order prior" is important — the player almost certainly goes in sequence (hole 7 after hole 6). This prior should be strong enough to resist switching to the wrong hole from a noisy single shot.

---

## Shot Accuracy from Orientation

### Concept

If we filter recorded shots for ones that went perfectly straight (aim direction matched GPS bearing to landing), and compare the setup orientation and impact orientation for those shots versus shots that went left or right, we can find correlations in the motion data.

**Specifically:**
- At setup: record pitch, roll, yaw at stable address position
- At impact: record yaw deviation from setup yaw (did the wrist rotate open or closed?)
- Cross-reference with actual shot direction (derived from GPS landing position vs GPS origin position)

Over enough shots, this should reveal repeatable orientation signatures for:
- Straight shots
- Pulled shots (closed face)
- Pushed shots (open face)
- Slices / fades
- Hooks / draws

### Live Feedback

Once the correlation is established, provide live feedback during setup:
- During the setup window (when state machine is in `accumulating`/`qualified`), display an indicator showing whether the current orientation matches the "straight shot" reference
- Color: green = matching reference, yellow = slight deviation, red = significant deviation
- This gives the user a chance to adjust before starting the stroke

**Implementation note:** The reference is player-specific. Calibrate it from the player's own historical data, not a generic norm.

---

## Backswing and Swing Speed Baselines

See SWING_DETECTION.md for the technical details on backswing percentage calculation.

### Ideal Swing Library

A separate mode where the user deliberately records "baseline" swings:
- User goes to driving range or practice area
- Opens a "Calibration" session in the app
- Hits their best shots for each club type
- These sessions are labeled as "ideal" and stored separately
- Future shots are compared against this library

This gives an objective personal reference rather than a dynamic average. Particularly useful for consistency tracking over time (e.g., "your driver backswing has shortened 8% compared to your calibration baseline from 3 months ago").

### Objective Reference for New Players

For players without a baseline, provide a generic reference based on best-practice swing mechanics (e.g., full backswing = 90° shoulder turn). This gives new players immediately useful feedback while they build their own data.

---

## Stroke Classification Tiers

Once stroke characterization is mature, strokes can be auto-classified:

| Tier | Detection Method | Estimated Accuracy |
|------|------------------|--------------------|
| Full swing (driver/woods/long irons) | Large accel + setup orientation | High (already works) |
| Full swing (mid irons) | Large accel + setup orientation | High |
| Half-swing / punch | Medium accel + short backswing extent | Medium (needs data) |
| Chip | Putt-like state machine with chip orientation | Medium (no data yet) |
| Putt | Putt state machine | High (working well) |
| Sand shot | TBD — may look like chip but orientation different | Unknown |

Classification feeds directly into:
- Better distance estimation (expected carry vs actual GPS displacement)
- Club prediction improvement (chip vs full iron from same distance looks different)
- Player analysis (what fraction of strokes are chips? are chip distances consistent?)

---

## Club Auto-Selection

Current state: the app predicts club based on distance to hole. This is a reasonable heuristic but ignores context.

**Improvements:**
1. Stroke classification narrows the club type (putt = putter, chip = short iron/wedge, etc.). Don't offer driver when the state machine detected a putting stroke shape.
2. Course memory: if the player consistently uses a 7-iron from 150 yards on this course (or in general), weight that club more heavily in prediction.
3. **Eventually zero-interaction:** If classification is confident enough, auto-confirm the detected club without requiring user confirmation.

---

## Implementation Priorities (Rough Order)

1. **Record chip shots** — the next data collection task. Everything chip-related is blocked on this.
2. **Switch DeviceMotion reference frame to xMagneticNorthZVertical** — enables swing direction vector without additional sensors.
3. **Extract swing direction vector at forward stroke peak** — foundation for auto-aim.
4. **Backswing extent metric** — useful and achievable with existing data; helps distinguish half-swings.
5. **Auto hole selection** — significant UX improvement, needs aim direction first.
6. **Chip detection state machine** — once chip data is characterized.
7. **Ideal swing calibration mode** — lower priority, needs the backswing/speed metrics to exist first.
8. **Live setup orientation feedback** — needs shot accuracy correlation data first.
