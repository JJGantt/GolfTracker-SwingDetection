-- A shared course's OSM data is fetched by the server, never sent by a client,
-- and the green detector's results on it are written once.
--
-- `register_osm_course` takes the course's name, outline and OSM data as
-- arguments, so a signed-in client calling it could still register any
-- osm_id with made-up contents. It is now callable only by the service role,
-- and the `register-osm-course` edge function is its one caller: the client
-- names the OSM element, the function fetches it from Overpass, checks it is a
-- named golf course, and builds the data itself.
--
-- `store_course_blob_detection` let any signed-in user replace a shared
-- course's detector results. Those results are the set every device and user
-- picks greens from (pick votes compare their blob ids), so on a shared course
-- the first stored set stands; a device whose run lost the race adopts the
-- stored set, which the function returns. On the caller's own course a new run
-- replaces the old one.

begin;

revoke execute on function register_osm_course(uuid, text, double precision, double precision, bigint, text, jsonb) from authenticated;

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
    if p_osm_id is null then
        raise exception 'osm_id required' using errcode = '22004';
    end if;
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

revoke execute on function register_osm_course(uuid, text, double precision, double precision, bigint, text, jsonb) from public, anon, authenticated;
grant execute on function register_osm_course(uuid, text, double precision, double precision, bigint, text, jsonb) to service_role;

-- Derivation is reached from registration, which now runs as the service role
-- and has no user.
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
    if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then
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

drop function if exists store_course_blob_detection(uuid, jsonb);

-- Stores a detector run and returns the results now in force for the course:
-- the caller's own when they were stored, the earlier set when a shared
-- course already had one, null when the caller cannot see the course.
create function store_course_blob_detection(p_course_id uuid, p_results jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_results jsonb;
begin
    if auth.uid() is null then
        raise exception 'not authenticated' using errcode = '42501';
    end if;
    update courses
       set blob_detection_results = p_results,
           blob_detection_at = now()
     where id = p_course_id
       and ((osm_id is not null and blob_detection_results is null)
            or (osm_id is null and created_by = auth.uid()));
    select blob_detection_results into v_results
      from courses
     where id = p_course_id and (osm_id is not null or created_by = auth.uid());
    return v_results;
end $$;

revoke execute on function store_course_blob_detection(uuid, jsonb) from public, anon;
grant execute on function store_course_blob_detection(uuid, jsonb) to authenticated;

commit;
