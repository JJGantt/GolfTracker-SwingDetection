-- False-negative training capture.
--
-- Background: when the user manually presses "add stroke," they swung but
-- the detector missed it. Between the previous successful stroke and that
-- manual press there are typically MANY shape-detector pairings that the
-- contact gate rejected — fidgeting, address-the-ball motion, walk-up,
-- the actual swing, etc. Exactly ONE of those rejections corresponds to
-- the real missed swing; the rest are noise.
--
-- We can't tell which is which automatically. So we save the whole group
-- here in a separate schema (NOT in `swing_events`, which holds only
-- confirmed-positive labeled data) and sift them manually later.
--
-- Each manual-add creates one `false_negative_groups` row + N
-- `false_negative_candidates` rows. The candidates' `label` column starts
-- NULL and is filled in during a later review pass:
--   * 'true_positive_match' for the one that's the real swing
--   * 'noise'               for the others
--
-- Once labeled, candidates can be lifted into the main training pipeline
-- (we'd treat them as new entries in the broader labeled set, not migrate
-- them into `swing_events` — keeping the provenance separate matters).

create table if not exists false_negative_groups (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null default auth.uid(),
    round_id uuid references rounds(id) on delete set null,
    stroke_id uuid references strokes(id) on delete set null,
    hole_number int,
    candidate_count int not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists idx_fng_user_id on false_negative_groups(user_id);
create index if not exists idx_fng_created_at on false_negative_groups(created_at desc);

alter table false_negative_groups enable row level security;

create policy "fn_groups_owner_read" on false_negative_groups
    for select to authenticated
    using (user_id = auth.uid());
create policy "fn_groups_owner_insert" on false_negative_groups
    for insert to authenticated
    with check (user_id = auth.uid());
create policy "fn_groups_owner_update" on false_negative_groups
    for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- Per-candidate row. Schema mirrors swing_events for the metadata fields
-- so the same downstream tooling can consume both, plus a few extras
-- specific to the false-negative pipeline (group_id, position_in_group,
-- gate_fails, label, stage).
create table if not exists false_negative_candidates (
    id uuid primary key default gen_random_uuid(),
    group_id uuid not null references false_negative_groups(id) on delete cascade,
    user_id uuid not null default auth.uid(),
    position_in_group int not null,    -- chronological order within the group, 0-indexed
    rejected_at timestamptz not null,
    stage text not null,                -- 'DM' (100Hz) or 'raw800'
    gate_fails text,                    -- comma-separated gate failure tokens

    -- Same metadata shape as swing_events for downstream re-use
    classification text,
    swing_type text,
    fs_peak_rot_mag double precision,
    bs_peak_rot_mag double precision,
    fs_bs_ratio double precision,
    contact_tv double precision,
    contact_n int,
    extrema_spread double precision,
    baseline_tv double precision,
    setup_duration double precision,
    bs_to_fs_gap double precision,
    club_type text,
    detection_mode text,
    storage_path text,                  -- path to per-candidate motion CSV in storage

    -- Fills in during manual review.
    --   NULL                  = unreviewed
    --   'true_positive_match' = this was the actual missed swing
    --   'noise'               = wasn't a swing
    label text,
    reviewed_at timestamptz,

    created_at timestamptz not null default now()
);

create index if not exists idx_fnc_group_id on false_negative_candidates(group_id);
create index if not exists idx_fnc_user_id on false_negative_candidates(user_id);
create index if not exists idx_fnc_unreviewed on false_negative_candidates(group_id) where label is null;

alter table false_negative_candidates enable row level security;

create policy "fn_cands_owner_read" on false_negative_candidates
    for select to authenticated
    using (user_id = auth.uid());
create policy "fn_cands_owner_insert" on false_negative_candidates
    for insert to authenticated
    with check (user_id = auth.uid());
create policy "fn_cands_owner_update" on false_negative_candidates
    for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());
