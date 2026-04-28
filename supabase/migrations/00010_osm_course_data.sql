-- Pooled cache of OpenStreetMap golf-course geometry (greens, tees, holes,
-- fairways, bunkers). Cross-user shared: when one user fetches a course's data
-- from Overpass, every other user playing nearby benefits.
--
-- Legal basis for storing + sharing: OpenStreetMap data is licensed under ODbL,
-- which permits caching and redistribution with attribution. Attribution text is
-- stored on every row and surfaced in the app's Settings/About screen.
--
-- Lookup model: users hit Overpass with a GPS center + ~1500m radius. We bucket
-- the center to 0.01 degrees (~1.1km) so users starting within the same course
-- collide on the same cache entry. When the user has a Course row, we also
-- store course_id so subsequent rounds at the same course skip the bucket
-- search and go straight to the linked entry.

create table if not exists osm_course_data (
    id uuid primary key default gen_random_uuid(),
    course_id uuid references courses(id) on delete set null,
    gps_bucket_lat numeric(5, 2) not null,  -- rounded to 0.01 deg (~1.1km)
    gps_bucket_lon numeric(6, 2) not null,
    center_latitude double precision not null,
    center_longitude double precision not null,
    radius_meters integer not null,
    -- Parsed OSM payload: { holes: [...], greens: [...], tees: [...], fairways: [...], bunkers: [...] }
    -- Schema mirrors the Swift OSMCourseData type. JSON keeps us flexible if the
    -- shape evolves without needing a new migration.
    data jsonb not null,
    attribution text not null default 'Map data © OpenStreetMap contributors (ODbL)',
    fetched_at timestamptz not null default now(),
    expires_at timestamptz,
    created_by uuid references auth.users(id) on delete set null,
    unique (gps_bucket_lat, gps_bucket_lon)
);

create index if not exists idx_osm_bucket on osm_course_data(gps_bucket_lat, gps_bucket_lon);
create index if not exists idx_osm_course on osm_course_data(course_id);
create index if not exists idx_osm_fetched on osm_course_data(fetched_at desc);

-- RLS: shared read, authenticated upsert, no delete (preserves the pool).
alter table osm_course_data enable row level security;

create policy "osm_read_all" on osm_course_data
    for select to authenticated
    using (true);

create policy "osm_insert_authenticated" on osm_course_data
    for insert to authenticated
    with check (auth.uid() is not null);

create policy "osm_update_authenticated" on osm_course_data
    for update to authenticated
    using (auth.uid() is not null)
    with check (auth.uid() is not null);
