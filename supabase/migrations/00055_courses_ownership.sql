-- Courses: an OSM course is shared and only server functions write it; any
-- other course belongs to the user who created it.
--
-- Until now every signed-in user could insert a course with any osm_id, and
-- update any row whose `created_by` was null — which is every OSM course,
-- since the resolver never set it. So anyone could rename or overwrite any
-- shared course. And user-created courses were readable by everyone, their
-- privacy left to a client-side filter in `RoundResolver.fetchSharedCoursesNear`.
--
-- After this migration:
--   * osm_id IS NOT NULL — a SHARED course. Everyone signed in reads it. No
--     client inserts, updates or deletes it; `register_osm_course` creates it
--     (and only fills in what an existing row lacks), and
--     `store_course_blob_detection` writes the green detector's results.
--   * osm_id IS NULL — a PERSONAL course, owned by `created_by`, which defaults
--     to the caller. Only its owner reads, writes or deletes it.

begin;

-- Personal courses with no owner were created by the app's plain upsert,
-- which never sent `created_by`. Their owner is whoever played them.
update courses c
   set created_by = (select r.user_id from rounds r where r.course_id = c.id order by r.date desc limit 1)
 where c.osm_id is null and c.created_by is null;

do $$
declare orphaned int;
begin
    select count(*) into orphaned from courses where osm_id is null and created_by is null;
    if orphaned > 0 then
        raise exception 'courses ownership backfill: % personal courses have no owner', orphaned;
    end if;
end $$;

alter table courses alter column created_by set default auth.uid();

drop policy if exists courses_read_all on courses;
drop policy if exists courses_insert_authenticated on courses;
drop policy if exists courses_update_owner_or_legacy on courses;
drop policy if exists courses_delete_owner on courses;

create policy courses_select_shared_or_own on courses
    for select to authenticated
    using (osm_id is not null or created_by = auth.uid());

create policy courses_insert_own on courses
    for insert to authenticated
    with check (osm_id is null and created_by = auth.uid());

create policy courses_update_own on courses
    for update to authenticated
    using (osm_id is null and created_by = auth.uid())
    with check (osm_id is null and created_by = auth.uid());

create policy courses_delete_own on courses
    for delete to authenticated
    using (osm_id is null and created_by = auth.uid());

revoke all on courses from anon;

-- A shared course for an OSM golf course. Creates the row if no course has
-- this osm_id; otherwise fills in only what the existing row lacks (its OSM
-- data, centre, scorecard id), so nobody can overwrite what another user
-- registered. Returns the id of the course for that osm_id, which is not
-- `p_id` when it already existed.
create or replace function register_osm_course(
    p_id uuid,
    p_name text,
    p_center_lat double precision,
    p_center_lon double precision,
    p_osm_id bigint,
    p_external_course_id text,
    p_osm_polygons jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id uuid;
    v_external text;
begin
    if auth.uid() is null then
        raise exception 'not authenticated' using errcode = '42501';
    end if;
    if p_osm_id is null then
        raise exception 'osm_id required' using errcode = '22004';
    end if;
    -- The scorecard id is unique across courses; one another course already
    -- holds is left off rather than failing the registration.
    v_external := case
        when p_external_course_id is not null
             and not exists (select 1 from courses where external_course_id = p_external_course_id
                                                    and osm_id is distinct from p_osm_id)
        then p_external_course_id
    end;

    insert into courses (id, name, center_lat, center_lon, osm_id, external_course_id, osm_polygons, created_by)
    values (p_id, p_name, p_center_lat, p_center_lon, p_osm_id, v_external, p_osm_polygons, null)
    on conflict (osm_id) do update
       set osm_polygons       = coalesce(courses.osm_polygons, excluded.osm_polygons),
           center_lat         = coalesce(courses.center_lat, excluded.center_lat),
           center_lon         = coalesce(courses.center_lon, excluded.center_lon),
           external_course_id = coalesce(courses.external_course_id, excluded.external_course_id)
    returning id into v_id;

    perform derive_osm_course_holes(v_id);
    return v_id;
end $$;

-- The green detector's output for a course the caller can see (shared, or
-- their own). It is the cross-device cache of a run the phone did; only the
-- two blob columns are written.
create or replace function store_course_blob_detection(p_course_id uuid, p_results jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_count int;
begin
    if auth.uid() is null then
        raise exception 'not authenticated' using errcode = '42501';
    end if;
    update courses
       set blob_detection_results = p_results,
           blob_detection_at = now()
     where id = p_course_id
       and (osm_id is not null or created_by = auth.uid());
    get diagnostics v_count = row_count;
    return v_count > 0;
end $$;

-- Shared holes come only from a shared course's OSM data: a personal course
-- carrying a copy of some other course's polygons gets none.
create or replace function derive_osm_course_holes(p_course_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_holes jsonb;
    v_greens jsonb;
    v_n int;
    v_added int;
begin
    if auth.uid() is null then
        raise exception 'not authenticated' using errcode = '42501';
    end if;

    select osm_polygons->'holes', osm_polygons->'greens'
      into v_holes, v_greens
      from courses where id = p_course_id and osm_id is not null;

    v_n := jsonb_array_length(coalesce(v_holes, '[]'::jsonb));
    if v_n = 0 or jsonb_array_length(coalesce(v_greens, '[]'::jsonb)) = 0 then
        return 0;
    end if;
    if exists (select 1 from jsonb_array_elements(v_holes) h where coalesce(h->>'ref', '') !~ '^[0-9]+$') then
        return 0;
    end if;
    if (select count(distinct (h->>'ref')::int) from jsonb_array_elements(v_holes) h) <> v_n
       or (select min((h->>'ref')::int) from jsonb_array_elements(v_holes) h) <> 1
       or (select max((h->>'ref')::int) from jsonb_array_elements(v_holes) h) <> v_n then
        return 0;
    end if;

    insert into holes (id, course_id, owner_id, number, latitude, longitude, par, created_at, updated_at)
    select gen_random_uuid(), p_course_id, null, (h->>'ref')::int,
           (h->'greenPoint'->>'latitude')::float8,
           (h->'greenPoint'->>'longitude')::float8,
           nullif(h->>'par', '')::int,
           now(), now()
      from jsonb_array_elements(v_holes) h
     where h->'greenPoint'->>'latitude' is not null
       and h->'greenPoint'->>'longitude' is not null
    on conflict (course_id, owner_id, number) do nothing;
    get diagnostics v_added = row_count;
    return v_added;
end $$;

revoke execute on function register_osm_course(uuid, text, double precision, double precision, bigint, text, jsonb) from public, anon;
revoke execute on function store_course_blob_detection(uuid, jsonb) from public, anon;
grant execute on function register_osm_course(uuid, text, double precision, double precision, bigint, text, jsonb) to authenticated;
grant execute on function store_course_blob_detection(uuid, jsonb) to authenticated;

commit;
