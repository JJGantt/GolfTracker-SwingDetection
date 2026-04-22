-- Swing events: one row per detected swing
-- Stores classification metadata; actual motion CSV lives in Storage bucket.
create table if not exists swing_events (
    id uuid primary key default gen_random_uuid(),
    device_id uuid not null,
    created_at timestamptz not null default now(),

    -- Detection classification
    classification text not null,          -- 'putt', 'swing', 'ambig'
    swing_type text,                       -- 'putt', 'partial', 'full' (post-classification)
    label text default 'positive',         -- 'positive', 'false_positive'

    -- Key detection metrics
    fs_peak_rot_mag double precision,
    bs_peak_rot_mag double precision,
    fs_bs_ratio double precision,
    peak_acceleration double precision,

    -- Contact gate values
    contact_tv double precision,
    contact_n integer,
    extrema_spread double precision,
    baseline_tv double precision,

    -- Setup / timing
    setup_duration double precision,
    bs_to_fs_gap double precision,

    -- Context
    club_type text,
    detection_mode text default 'unifDetect',

    -- Pointer to motion CSV in Storage
    storage_path text
);

-- Index for common queries
create index if not exists idx_swing_events_device on swing_events(device_id);
create index if not exists idx_swing_events_created on swing_events(created_at desc);
create index if not exists idx_swing_events_classification on swing_events(classification);

-- Row-Level Security: anon users can INSERT only, nothing else.
-- Service-role key (used from Mac for ML queries) bypasses RLS entirely.
alter table swing_events enable row level security;

create policy "anon_insert_only"
    on swing_events
    for insert
    to anon
    with check (true);

-- Storage bucket for motion CSVs
insert into storage.buckets (id, name, public)
values ('swing-motion', 'swing-motion', false)
on conflict (id) do nothing;

-- Storage RLS: anon can upload to swing-motion bucket
create policy "anon_upload_swing_motion"
    on storage.objects
    for insert
    to anon
    with check (bucket_id = 'swing-motion');

-- Service role can read everything (for ML export); anon cannot read.
