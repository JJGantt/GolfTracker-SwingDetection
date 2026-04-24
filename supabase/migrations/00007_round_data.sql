-- Normalized user-account data: clubs, courses, rounds, strokes, targets.
-- Keyed to auth.users via user_id. Every top-level table has RLS enforcing
-- "users can only access their own rows". Child tables enforce ownership via
-- their parent's user_id.

-- =============================================================================
-- Clubs
-- =============================================================================

create table if not exists club_types (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    name text not null,
    is_default boolean not null default false,
    average_distance integer,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_club_types_user on club_types(user_id);

create table if not exists clubs (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    name text not null,
    club_type_id uuid not null references club_types(id) on delete cascade,
    is_default boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_clubs_user on clubs(user_id);
create index if not exists idx_clubs_type on clubs(club_type_id);

create table if not exists club_sets (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    name text not null,
    is_active boolean not null default false,
    date_created timestamptz not null default now(),
    date_modified timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_club_sets_user on club_sets(user_id);

create table if not exists club_set_type_selections (
    id uuid primary key default gen_random_uuid(),
    club_set_id uuid not null references club_sets(id) on delete cascade,
    type_id uuid not null references club_types(id) on delete cascade,
    active_club_id uuid references clubs(id) on delete set null,
    unique (club_set_id, type_id)
);

create index if not exists idx_css_set on club_set_type_selections(club_set_id);

-- =============================================================================
-- Courses & holes
-- =============================================================================

create table if not exists courses (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    name text not null,
    rating double precision,
    slope integer,
    city text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_courses_user on courses(user_id);

create table if not exists holes (
    id uuid primary key,
    course_id uuid not null references courses(id) on delete cascade,
    number integer not null,
    latitude double precision,
    longitude double precision,
    par integer,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (course_id, number)
);

create index if not exists idx_holes_course on holes(course_id);

-- =============================================================================
-- Rounds & children
-- =============================================================================

create table if not exists rounds (
    id uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    course_id uuid references courses(id) on delete set null,
    course_name text not null,
    date timestamptz not null,
    current_hole_index integer not null default 0,
    completed_holes integer[] not null default '{}',
    hole_detection_enabled boolean,
    location_test_mode_enabled boolean,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_rounds_user on rounds(user_id);
create index if not exists idx_rounds_course on rounds(course_id);
create index if not exists idx_rounds_date on rounds(date desc);

-- Round-time snapshot of course holes. Round.holes in Swift is intentionally a
-- copy (so edits to the parent course don't rewrite history).
create table if not exists round_holes (
    id uuid primary key,
    round_id uuid not null references rounds(id) on delete cascade,
    number integer not null,
    latitude double precision,
    longitude double precision,
    par integer,
    unique (round_id, number)
);

create index if not exists idx_round_holes_round on round_holes(round_id);

create table if not exists strokes (
    id uuid primary key,
    round_id uuid not null references rounds(id) on delete cascade,
    hole_number integer not null,
    stroke_number integer not null,
    latitude double precision not null,
    longitude double precision not null,
    club_id uuid not null,
    timestamp timestamptz not null,
    is_penalty boolean not null default false,
    trajectory_heading double precision,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_strokes_round on strokes(round_id);
create index if not exists idx_strokes_round_hole on strokes(round_id, hole_number);

create table if not exists targets (
    id uuid primary key,
    round_id uuid not null references rounds(id) on delete cascade,
    hole_number integer not null,
    latitude double precision not null,
    longitude double precision not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists idx_targets_round on targets(round_id);

-- =============================================================================
-- RLS: owner-only access via auth.uid()
-- =============================================================================

alter table club_types enable row level security;
alter table clubs enable row level security;
alter table club_sets enable row level security;
alter table club_set_type_selections enable row level security;
alter table courses enable row level security;
alter table holes enable row level security;
alter table rounds enable row level security;
alter table round_holes enable row level security;
alter table strokes enable row level security;
alter table targets enable row level security;

-- Tables with user_id column: direct match
create policy "own_club_types" on club_types
    for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own_clubs" on clubs
    for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own_club_sets" on club_sets
    for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own_courses" on courses
    for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "own_rounds" on rounds
    for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Child tables: verify ownership via parent
create policy "own_css" on club_set_type_selections
    for all to authenticated
    using (exists (select 1 from club_sets cs where cs.id = club_set_id and cs.user_id = auth.uid()))
    with check (exists (select 1 from club_sets cs where cs.id = club_set_id and cs.user_id = auth.uid()));

create policy "own_holes" on holes
    for all to authenticated
    using (exists (select 1 from courses c where c.id = course_id and c.user_id = auth.uid()))
    with check (exists (select 1 from courses c where c.id = course_id and c.user_id = auth.uid()));

create policy "own_round_holes" on round_holes
    for all to authenticated
    using (exists (select 1 from rounds r where r.id = round_id and r.user_id = auth.uid()))
    with check (exists (select 1 from rounds r where r.id = round_id and r.user_id = auth.uid()));

create policy "own_strokes" on strokes
    for all to authenticated
    using (exists (select 1 from rounds r where r.id = round_id and r.user_id = auth.uid()))
    with check (exists (select 1 from rounds r where r.id = round_id and r.user_id = auth.uid()));

create policy "own_targets" on targets
    for all to authenticated
    using (exists (select 1 from rounds r where r.id = round_id and r.user_id = auth.uid()))
    with check (exists (select 1 from rounds r where r.id = round_id and r.user_id = auth.uid()));
