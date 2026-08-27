# Backend — Supabase

StrokeSaver uses [Supabase](https://supabase.com) as its cloud backend. Supabase is a hosted Postgres database + file storage + auth service with an auto-generated REST API. No custom server code — the iOS app talks directly to Supabase's endpoints.

---

## Project Details

| Field | Value |
|---|---|
| **Project URL** | `https://oumnicnvayqrbfbljgyl.supabase.co` |
| **REST API base** | `https://oumnicnvayqrbfbljgyl.supabase.co/rest/v1/` |
| **Storage API base** | `https://oumnicnvayqrbfbljgyl.supabase.co/storage/v1/` |
| **Publishable key** | `sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi` (safe for client-side use) |
| **Secret key** | Stored in env var `SUPABASE_SERVICE_ROLE_KEY` on Mac — never embed in app code |
| **Region** | Check dashboard → Project Settings → General |
| **Supabase CLI** | `brew install supabase/tap/supabase`, linked via `supabase link --project-ref oumnicnvayqrbfbljgyl` |

### Key Format (updated 2026)

Supabase now uses `sb_publishable_*` keys instead of the older JWT `eyJ...` format. The publishable key maps to the **`postgres`** Postgres role (not `anon` as in older Supabase documentation). This affects Row-Level Security policy authoring — policies targeting `to anon` will NOT match requests made with the publishable key. Policies must either omit the role clause (apply to all roles) or target `postgres` explicitly.

### Authentication Headers

Every REST API request requires two headers:
```
apikey: sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi
Authorization: Bearer sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi
```
Both use the same publishable key for unauthenticated requests. When user auth is added later, `Authorization` will carry the user's JWT instead.

---

## What Lives Where

| Location | Contents |
|---|---|
| **Supabase cloud** | Postgres database (tables, indexes, policies), Storage buckets (CSV blobs). NOT on this machine. |
| **`supabase/migrations/`** (in this repo) | SQL migration files that define the schema. Version-controlled. Can recreate the DB from scratch by running `supabase db push`. |
| **`supabase/.temp/`** (gitignored) | CLI state — project linking, version cache. Auto-generated, don't touch. |
| **iOS app code** (future) | Swift service layer that uploads swing data to Supabase. Lives in `GolfTracker/Services/` or `GolfWatch Watch App/Services/`. |

---

## Current Schema

### Table: `swing_events`

One row per detected swing. Stores classification metadata; the motion CSV lives
in the Storage bucket.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid (PK) | Auto-generated |
| `user_id` | uuid | Owner. Replaced `device_id`, which 00008 **dropped** |
| `created_at` | timestamptz | Detection time. Note there is no `updated_at` — a label flip leaves no timestamp here |
| `classification` | text | `putt`, `swing`, `ambig` |
| `swing_type` | text | `putt`, `partial`, `full` (post-classification) |
| `label` | text | `positive`, `false_positive`. **Only ever a statement about the DETECTOR** — see below |
| `confidence` | text | `high` (explicit user action) or `low` (implicit). Default `low` |
| `not_a_stroke_reason` | text | 00047. Why a *correct* detection wasn't a counted stroke. NULL = it counted. `'practice'` = practice-swing replacement |
| `test_session_id` | uuid | 00047. Set when the detection came from Swing Test Mode. NULL for round play. Soft reference to `swing_test_sessions` |
| `fs_peak_rot_mag` | double | Forward-stroke peak rotation magnitude |
| `bs_peak_rot_mag` | double | Backstroke peak rotation magnitude |
| `fs_bs_ratio` | double | FS/BS ratio |
| `peak_acceleration` | double | Peak userAccel magnitude |
| `contact_tv` | double | Total variation (contact gate) |
| `contact_n` | int | Extrema count (contact gate) |
| `extrema_spread` | double | σ/σ_max (contact gate) |
| `baseline_tv` | double | Baseline total variation |
| `setup_duration` | double | Seconds in setup before stroke |
| `bs_to_fs_gap` | double | Seconds between BS top and FS peak |
| `club_type` | text | Club used |
| `detection_mode` | text | Default `unifDetect` |
| `storage_path` | text | Path to motion CSV in `swing-motion` |

**`label` and `not_a_stroke_reason` are orthogonal on purpose.** `label` answers
only "did the detector correctly identify a golf swing?" A practice swing is a
**correct detection** that simply isn't a shot, so it is `positive/high` +
`not_a_stroke_reason='practice'`. Before 00047 it was written as
`false_positive/high` — the same call undo makes — which trained the model against
its own correct answers. Pre-00047 `false_positive` rows are consequently a blend
of genuine misfires and mislabeled practice swings; `swing_events` alone cannot
split them (no flip timestamp), but joining `client_events` on
`swing.update.falsePositive.ok` can. See `docs/SWING_DETECTION.md`.

### Table: `swing_test_sessions` (00047)

One row per Swing Test Mode session — the detector run with no round attached, for
deliberately producing labeled true positives, false positives and misses.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid (PK) | Referenced by `swing_events.test_session_id` (soft) |
| `user_id` | uuid | Owner |
| `started_at` / `ended_at` | timestamptz | `ended_at` NULL while running |
| `notes` | text | Free text |
| `detection_mode` | text | Default `unifDetect` |
| `detected_count` | int | Counters **as the watch displayed them**, written on stop, so a |
| `false_positive_count` | int | session can be audited against its rows without assuming |
| `lookback_count` | int | every upload landed |

### Tables: `false_negative_groups` / `false_negative_candidates` (00028, 00030, 00047)

Missed swings. A group is one miss; candidates are the detector's rejected shapes
around it. `capture_reason` distinguishes the two ways a miss is captured, which
exist because they cover genuinely different failures:

| `capture_reason` | Trigger | Content |
|---|---|---|
| `rejected_shapes` | Manual stroke add during a round | N candidates, one of which is the real missed swing; each carries `gate_fails` + `stage`. Only reachable when the shape **paired** and a post-pairing gate killed it |
| `lookback` | "Missed It" button | Raw motion window on the group's own `storage_path`, plus any rejections inside it. `candidate_count = 0` is **the finding** — nothing paired at all |

Group columns beyond the originals: `capture_reason`, `storage_path` (lookback's raw
window), `test_session_id`, `window_seconds` (actual span — shorter than the 15s
maximum whenever a detection or earlier capture already covered the ground behind
it). `stroke_id` has **no FK** (dropped in 00030): the stroke is written locally and
synced async, so a hard constraint lost the group to a race.

Candidate `label` starts NULL and is filled during review with
`'true_positive_match'` (the real missed swing) or `'noise'`.

### Storage Bucket: `swing-motion`

Private. Paths are keyed by **`user_id`**, not device:

| Path | Contents |
|---|---|
| `{userId}/{eventId}.csv` | Detection motion slice, 16 columns |
| `{userId}/{eventId}_raw.csv` | 800 Hz raw accel for that detection, when running |
| `{userId}/false_negatives/{groupId}/{position}.csv` | Per-candidate motion |
| `{userId}/lookback/{groupId}/window.csv` | Lookback raw window |
| `{userId}/lookback/{groupId}/window_raw.csv` | Lookback 800 Hz, when running |

Detection slices cover `bsTopT − 2.0s` to `fsPeakT + 1.0s`. Historical
`sensor_capture/` objects may still sit in the bucket; nothing writes there any more
(that recorder was removed). Storage policies compare
folder to `auth.uid()` **case-insensitively** — Swift's `UUID.uuidString` is
uppercase and `auth.uid()::text` is not, which silently 403'd every nested upload
until 00030.

---

## Row-Level Security (RLS)

**Enabled and owner-scoped.** RLS was disabled during early development (00004),
which is what the old key-format note below described; 00008 dropped `device_id`,
added `user_id`, re-enabled RLS and installed per-user policies. Every swing table
now follows the same shape:

```sql
alter table swing_events enable row level security;
create policy swing_events_select_own on swing_events
    for select to authenticated using (user_id = auth.uid());
```

`false_negative_groups`, `false_negative_candidates` and `swing_test_sessions`
carry matching owner read/insert/update policies. The service_role key bypasses RLS
entirely and is what ML analysis from the Mac should use.

---

## Accessing Data

### From the Supabase Dashboard
Web UI at `https://supabase.com/dashboard` → Table Editor or SQL Editor. Good for quick exploration, ad-hoc queries, CSV export.

### From curl (testing)
```bash
# Insert a row
curl -X POST "https://oumnicnvayqrbfbljgyl.supabase.co/rest/v1/swing_events" \
  -H "apikey: sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi" \
  -H "Authorization: Bearer sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d '{"user_id": "...", "classification": "swing", "club_type": "Driver"}'
# NOTE: inserts need a USER JWT in the Authorization header, not the publishable
# key — RLS scopes every row to auth.uid(). Use the service_role key for analysis
# reads instead; it bypasses RLS.

# Query rows
curl "https://oumnicnvayqrbfbljgyl.supabase.co/rest/v1/swing_events?select=*&classification=eq.putt" \
  -H "apikey: sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi" \
  -H "Authorization: Bearer sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi"

# Delete a row
curl -X DELETE "https://oumnicnvayqrbfbljgyl.supabase.co/rest/v1/swing_events?id=eq.{uuid}" \
  -H "apikey: sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi" \
  -H "Authorization: Bearer sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi"
```

### From Python (ML analysis)
```python
from supabase import create_client
import pandas as pd
import os

# Use service_role key for full access (bypasses RLS)
sb = create_client(
    "https://oumnicnvayqrbfbljgyl.supabase.co",
    os.environ["SUPABASE_SERVICE_ROLE_KEY"]
)

# Query all swing events
data = sb.table("swing_events").select("*").execute()
df = pd.DataFrame(data.data)

# Download a specific motion CSV from Storage (paths are keyed by USER, not device)
res = sb.storage.from_("swing-motion").download(f"{user_id}/{event_id}.csv")

# Round play only, CSV-backed and labeled:
sb.table("swing_events").select("*") \
  .is_("test_session_id", "null") \
  .not_.is_("storage_path", "null") \
  .not_.is_("label", "null").execute()

# True positives, including practice swings (a correct detection either way):
sb.table("swing_events").select("*").eq("label", "positive").execute()

# Misses whose raw window was captured because nothing paired:
sb.table("false_negative_groups").select("*") \
  .eq("capture_reason", "lookback").eq("candidate_count", 0).execute()
```

Install: `pip install supabase pandas`

### From iOS / Swift
```swift
// URLSession POST to insert a swing event
var request = URLRequest(url: URL(string: "https://oumnicnvayqrbfbljgyl.supabase.co/rest/v1/swing_events")!)
request.httpMethod = "POST"
request.setValue("sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi", forHTTPHeaderField: "apikey")
request.setValue("Bearer sb_publishable_i0loB-AZw2qGokBJzHGSKA_VGgAgjBi", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = try JSONEncoder().encode(swingEventPayload)
URLSession.shared.dataTask(with: request) { data, response, error in ... }.resume()
```

### Python visualizer (direct from Supabase)
```bash
# All events — full multi-subplot breakdown (Rotation, Raw 800Hz, DM UserAccel, Orientation)
python3 swing_detection/unified_visualize.py --supabase

# Last N events
python3 swing_detection/unified_visualize.py --supabase 10

# Only false positives
python3 swing_detection/unified_visualize.py --supabase --label-filter false_positive

# Last 20 positives
python3 swing_detection/unified_visualize.py --supabase 20 --label-filter positive

# Custom output dir
python3 swing_detection/unified_visualize.py --supabase -o /tmp
```
Downloads DM CSVs + 800Hz raw accel CSVs (when available) directly from Supabase storage, names them for the visualizer's `find_raw_accel_path` convention, and runs `plot_stitched`. Output is an interactive HTML file.

### Supabase CLI
```bash
# Link to project (one-time)
supabase link --project-ref oumnicnvayqrbfbljgyl

# Push new migrations
supabase db push

# Check project status
supabase status
```

---

## Migrations

Schema changes are managed as sequential SQL files in `supabase/migrations/`:

| File | Description |
|---|---|
| `00001_swing_events.sql` | Create `swing_events`, indexes, storage bucket. Original RLS policies (superseded). |
| `00002`–`00004` | Early RLS debugging; 00004 disabled RLS for development. Superseded by 00008. |
| `00005_add_confidence.sql` | `swing_events.confidence`. |
| `00008_swing_events_user_id.sql` | **Dropped `device_id`**, added `user_id`, re-enabled RLS with owner-scoped policies. |
| `00028_false_negative_groups.sql` | `false_negative_groups` + `false_negative_candidates`. |
| `00030_false_negative_fixes.sql` | Dropped the `stroke_id` FK (async write race); made storage folder comparison case-insensitive. |
| `00038`–`00040` | Storage-path repairs; NULL labels for metadata-only rows. |
| `00047_swing_test_sessions.sql` | `not_a_stroke_reason` + `test_session_id` on `swing_events`; `swing_test_sessions`; lookback columns on `false_negative_groups`. |

The full list is `supabase/migrations/` — this table covers the swing pipeline only;
the majority of migrations concern rounds, courses and the elevation field.

To recreate the database from scratch: `supabase db push` applies all migrations in order.

---

## Upload Flow

### Ordering: CSV first, then the metadata row

`SupabaseUploader.upload(event:)` uploads the motion CSV **before** inserting the
`swing_events` row, and writes `label`/`confidence` only if the CSV landed. A row
whose CSV failed is inserted with both NULL (metadata-only). That makes

```
storage_path IS NOT NULL AND label IS NOT NULL
```

a reliable filter for CSV-backed labeled samples, and keeps detection metadata for
the rest rather than discarding it.

### Pending event lifecycle

Auto-add is the live path and does **not** use the pending slot: it uploads
immediately as `positive/low` and returns the event id so the UI can flip the row
later. The pending slot only exists for manual-suggest mode, where the event waits
for the popup.

| Trigger | Label | Confidence |
|---|---|---|
| Auto-add detection | `positive` | `low` |
| Undo an auto-added stroke | `false_positive` | `high` |
| Practice-swing replacement | `positive` + `not_a_stroke_reason='practice'` | `high` |
| Manual-suggest: user accepts | `positive` | `high` |
| Manual-suggest: user rejects (X) | `false_positive` | `high` |
| Manual-suggest: next detection, no action | `false_positive` | `low` |
| `rejectAll` farming mode | `false_positive` | `high` |

`positive/low` is deliberately weak — the detector fired and the user did not
object, which includes detections nobody noticed. Undo and practice replacement are
edits to an already-uploaded row (`markFalsePositive` / `markPracticeSwing`), not
flushes.

**`rejectAll` has no UI.** It persists under UserDefaults `supabaseRejectAll` and
nothing writes it but its own `didSet`, so it currently cannot be turned on from the
app.

### Swing Test Mode

`SwingTestSession` inserts a `swing_test_sessions` row, sets
`SupabaseUploader.currentTestSessionId` for the session's lifetime — which stamps
every event constructed while it is set, so the detector needs no knowledge of test
mode — and writes the counters back on stop. It forces `autoAdd` on (manual mode
never publishes the event id the false-positive button needs) and restores the
previous value afterwards.

### Lookback capture

`uploadLookbackCapture` writes a `false_negative_groups` row with
`capture_reason='lookback'`, uploads the raw window (and 800 Hz stream when
running), then inserts any in-window rejections as ordinary candidates. The window
ends at the current sensor time and starts at the later of *now − 15s* and a
boundary that advances on every fired detection and every capture, so it cannot
re-upload motion another record already covers.

---

## Current Status

- [x] `swing_events` with detection metrics, owner-scoped RLS, `user_id`
- [x] `swing-motion` storage bucket + per-user path policies
- [x] Watch upload service — CSV then metadata row, with the NULL-label fallback
- [x] False-positive labeling from undo; practice swings separated from it (00047)
- [x] False-negative capture — rejected-shape groups and raw lookback windows
- [x] Swing Test Mode sessions
- [x] Migrations version-controlled and pushed via `supabase db push`
- [ ] **Review tooling for `false_negative_candidates`** — every candidate's `label`
      is still NULL and nothing sifts them into `true_positive_match` / `noise`
- [ ] **Confirm-a-detection affordance** — nothing promotes `positive/low` to
      `positive/high`, so the positive class stays largely unverified

---

## Future Phases

Phase 2 (auth + user rounds) is **done**: Sign in with Apple, `rounds`,
`profiles`, and `auth.uid()`-scoped RLS all shipped. There was no anonymous →
authenticated migration — 00008 dropped `device_id` outright, so pre-auth swing
history is not attributable to a user.

### Phase 3: Paid Tier
- In-app purchase (StoreKit) for data-sharing opt-out
- `profiles.is_paid` flag gates upload requirement
- GDPR compliance: paid tier = "freely given" consent for free-tier data collection

### Phase 4: Analytics / ML Pipeline
- Scheduled export to Parquet for batch analysis
- Detection-quality dashboard (false-positive rate over time)
- Per-user threshold tuning from aggregated swing corpus
