# Backend — Supabase

GolfTracker uses [Supabase](https://supabase.com) as its cloud backend. Supabase is a hosted Postgres database + file storage + auth service with an auto-generated REST API. No custom server code — the iOS app talks directly to Supabase's endpoints.

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

One row per detected swing. Stores classification metadata; actual motion CSV lives in the Storage bucket.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid (PK) | Auto-generated |
| `device_id` | uuid | Anonymous per-install identifier |
| `created_at` | timestamptz | Auto-set to now() |
| `classification` | text | `putt`, `swing`, `ambig` |
| `swing_type` | text | `putt`, `partial`, `full` (post-classification) |
| `label` | text | `positive`, `false_positive` (default: `positive`) |
| `confidence` | text | `high` (explicit user action) or `low` (implicit flush). Default: `low`. |
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
| `club_type` | text | Club used (e.g., `Driver`, `Putt`) |
| `detection_mode` | text | Default `unifDetect` |
| `storage_path` | text | Path to motion CSV in `swing-motion` bucket |

**Indexes:** `device_id`, `created_at DESC`, `classification`.

### Storage Bucket: `swing-motion`

Private bucket for motion CSV blobs. Files organized as `{device_id}/{event_id}.csv`.

Each CSV is the same format as Data Collection Mode output: 15-channel device-motion data (SensorTime, UserAccelXYZ, RotationXYZ, GravityXYZ, Pitch/Roll/Yaw) covering `setupStartT − 0.5s` to `fsPeakT + 1.0s`.

---

## Row-Level Security (RLS)

**Currently disabled** for development/debugging. RLS was enabled initially but the new publishable key format (mapping to `postgres` role instead of `anon`) caused policy mismatches. Re-enable when auth is added.

When re-enabling, policies should omit the role clause or target `postgres`:
```sql
-- This works with the new key format:
create policy "allow_insert" on swing_events for insert with check (true);

-- This does NOT work (old format, targets 'anon' role):
create policy "anon_insert" on swing_events for insert to anon with check (true);
```

Once user auth is added, policies will use `auth.uid()` to scope access per user.

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
  -d '{"device_id": "...", "classification": "swing", "club_type": "Driver"}'

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

# Download a specific motion CSV from Storage
res = sb.storage.from_("swing-motion").download(f"{device_id}/{event_id}.csv")
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
| `00001_swing_events.sql` | Create `swing_events` table, indexes, storage bucket. Original RLS policies (stale). |
| `00002_whoami.sql` | Debug helper to check Postgres role mapping (cleaned up in 00003). |
| `00003_fix_rls.sql` | Attempted RLS fix — broadened policies. Dropped `whoami()`. |
| `00004_debug_rls.sql` | Disabled RLS for development. |

To recreate the database from scratch: `supabase db push` applies all migrations in order.

---

## Upload Flow

Every detected swing eventually uploads to Supabase — the label and confidence depend on the mode and user action.

### Pending Event Lifecycle

Each detection creates a **pending event** (metadata + motion slice). The event stays pending until one of these triggers flushes it:

| Trigger | Label | Confidence |
|---|---|---|
| User explicitly undoes the stroke (auto-add mode) | `false_positive` | `high` |
| User explicitly taps to add the stroke (manual-add mode) | `positive` | `high` |
| Next detection fires without user action (auto-add: no undo) | `positive` | `low` |
| Next detection fires without user action (manual-add: no tap) | `false_positive` | `low` |
| Round ends / detection stops | Inherits current tentative label | `low` |
| Farming mode (reject-all toggle) | `false_positive` | `high` |

### Mode Logic

**Auto-add mode** (`autoAdd = true`):
- Detection → stroke auto-added → pending event with tentative label `positive`
- Undo → immediately flush as `false_positive` / `high`, upload to Supabase
- Next detection without undo → flush previous as `positive` / `low`, hold new as pending

**Manual-add mode** (`autoAdd = false`):
- Detection → cyan icon shown, stroke NOT added → pending event with tentative label `false_positive`
- User taps icon → flip label to `positive` / `high`
- Next detection without tap → flush previous as `false_positive` / `low`, hold new as pending

**Farming mode** (new `rejectAll` toggle):
- Detection → immediately upload as `false_positive` / `high`
- No pending state — flush on every detection
- Purpose: collect false-positive corpus during casual wear (walking, daily activity)

### Upload Payload

Each flush sends two things to Supabase:
1. **Metadata row** → `POST /rest/v1/swing_events` (JSON with classification, gate values, label, confidence, etc.)
2. **Motion CSV** → upload to `swing-motion` bucket at `{device_id}/{event_id}.csv`

The `storage_path` column in the metadata row points at the CSV.

---

## Current Status

- [x] Supabase project created and linked
- [x] `swing_events` table with detection metrics
- [x] `swing-motion` storage bucket for CSV blobs
- [x] REST API verified (insert, read, delete all working)
- [x] Supabase CLI installed and linked
- [x] Migrations version-controlled in repo
- [ ] **iOS Swift upload service** — POST metadata + upload CSV after each detection
- [ ] **Storage upload** — wire CSV blob upload to `swing-motion` bucket
- [ ] **Python analysis setup** — `supabase-py` + service_role key in env var
- [ ] **Secret key env var** — store `SUPABASE_SERVICE_ROLE_KEY` in `~/.zshrc` or `.env`

---

## Future Phases

### Phase 2: Auth + User Rounds
- Sign in with Apple via Supabase Auth
- `rounds` table (offline-first on device, background sync to Supabase)
- `profiles` table (user metadata, paid-tier flag)
- RLS re-enabled with `auth.uid()` scoping
- Anonymous → authenticated migration (link device_id history to user account)

### Phase 3: Paid Tier
- In-app purchase (StoreKit) for data-sharing opt-out
- `profiles.is_paid` flag gates upload requirement
- GDPR compliance: paid tier = "freely given" consent for free-tier data collection

### Phase 4: Analytics / ML Pipeline
- Scheduled export to Parquet for batch analysis
- Detection-quality dashboard (false-positive rate over time)
- Per-user threshold tuning from aggregated swing corpus
