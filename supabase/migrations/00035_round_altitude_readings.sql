-- Per-round path samples with paired barometric relative altitude.
--
-- Captured continuously while a round is active (CMAltimeter
-- startRelativeAltitudeUpdates), one row per ~3m of GPS movement. The
-- relative-altitude value is referenced to whatever the altimeter happened
-- to be at on `startRelativeAltitudeUpdates` — it is NOT comparable across
-- users or across sessions on its own. Cross-user height maps come from
-- the modeling layer (see docs/ELEVATION_TRACKING.md), which solves for
-- per-user offsets using on-green averages and off-green spatial
-- crossings.
--
-- This table is the raw capture. No deduplication, no aggregation. Each
-- row stands alone with its (round_id, recorded_at) primary key.

create table if not exists round_altitude_readings (
    id              uuid primary key default gen_random_uuid(),
    round_id        uuid not null references rounds(id) on delete cascade,
    user_id         uuid not null references auth.users(id) on delete cascade,
    hole_number     int2 not null,
    lat             float8 not null,
    lon             float8 not null,
    rel_alt_meters  real not null,
    recorded_at     timestamptz not null,
    created_at      timestamptz not null default now()
);

create index if not exists idx_round_altitude_readings_round
    on round_altitude_readings(round_id);
create index if not exists idx_round_altitude_readings_user
    on round_altitude_readings(user_id);

alter table round_altitude_readings enable row level security;

create policy rar_select_own on round_altitude_readings
    for select to authenticated using (user_id = auth.uid());

create policy rar_insert_own on round_altitude_readings
    for insert to authenticated with check (user_id = auth.uid());

create policy rar_delete_own on round_altitude_readings
    for delete to authenticated using (user_id = auth.uid());
