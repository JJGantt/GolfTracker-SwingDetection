-- Detector thresholds live in the database, not in the binary.
--
-- Every threshold change previously cost a build, an upload, and a wait for the
-- watch app to sync — minutes per experiment, for experiments that take seconds
-- to evaluate. Worse, it made tuning and analysis race each other: the numbers a
-- stroke was judged against were whatever happened to be compiled into the build
-- on the wrist that day, and nothing recorded which.
--
-- Key/value rather than a column per threshold, so adding a parameter never
-- needs a migration. Every value is numeric (Int params are stored as their
-- double and rounded on read).
--
-- Scoped per user for consistency with every other table here; the seed below
-- writes no user_id, so `defaults` rows (user_id IS NULL) act as the shared
-- baseline and a user row overrides it when present.

create table if not exists detector_config (
    user_id    uuid references auth.users(id) on delete cascade,
    key        text not null,
    value      double precision not null,
    updated_at timestamptz not null default now(),
    note       text
);

-- One row per (user, key); NULL user_id is the shared default. A partial unique
-- index is required because NULL is not comparable in a normal unique constraint.
create unique index if not exists detector_config_user_key
    on detector_config(user_id, key) where user_id is not null;
create unique index if not exists detector_config_default_key
    on detector_config(key) where user_id is null;

alter table detector_config enable row level security;

-- Everyone reads the shared defaults and their own overrides.
create policy detector_config_read on detector_config
    for select to authenticated
    using (user_id is null or user_id = auth.uid());
create policy detector_config_write_own on detector_config
    for insert to authenticated with check (user_id = auth.uid());
create policy detector_config_update_own on detector_config
    for update to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy detector_config_delete_own on detector_config
    for delete to authenticated using (user_id = auth.uid());

-- The shared default rows are seeded from the private algorithms repo
-- (supabase/seed/detector_config.sql), not here. Until they exist the watch does
-- not detect at all, by design (see DetectorConfig).

-- Which thresholds a row was judged under. Without this, tunable thresholds
-- quietly destroy the analysis: rows from either side of a change get pooled and
-- compared as though they meant the same thing. Every distribution used to argue
-- about a gate depends on knowing the gate.
alter table swing_events
    add column if not exists detector_config jsonb;
alter table false_negative_candidates
    add column if not exists detector_config jsonb;

comment on column swing_events.detector_config is
    'Snapshot of the thresholds active when this detection was judged. NULL for '
    'rows predating 00048, which were judged under the build-65 compiled defaults.';
