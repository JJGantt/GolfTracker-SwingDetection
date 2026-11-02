-- Course holes: shared only when OpenStreetMap determines them; personal otherwise.
--
-- A `holes` row is one of two kinds, told apart by `owner_id`:
--
--   * owner_id IS NULL — a SHARED hole, derived from the course's OSM data
--     where the hole order is determined (every OSM hole carries an integer
--     ref and the refs are exactly 1..N, the resolver's `full` tier). Every
--     signed-in user reads these. No client writes them: they are created only
--     by `derive_osm_course_holes`, which builds them on the server from the
--     course's `osm_polygons`, and nothing client-side may update or delete
--     them.
--   * owner_id = a user — a PERSONAL hole, one the user placed or moved
--     themselves. Only that user can read, write or delete it.
--
-- A course can carry both for one number: a user who moves a shared green gets
-- a personal hole for that number, and their own hole is the one their devices
-- use. Hence the uniqueness is (course_id, owner_id, number) with NULLs not
-- distinct: one shared row per number, plus at most one per user.
--
-- Clients write personal holes through `upsert_my_course_hole` and
-- `delete_my_course_hole`, keyed by (course, caller, number) — the caller's
-- local hole id is only a suggestion for a new row, because the hole it edits
-- may be the shared row, whose id is taken. `owner_id` defaults to
-- `auth.uid()` so a plain insert from a client is a personal hole.

begin;

alter table holes add column owner_id uuid references auth.users(id) on delete cascade;

-- Backfill. Shared: the row is on a `full`-tier OSM course and sits exactly on
-- the OSM green point for its own ref, i.e. it is the row the resolver derived
-- and nobody has moved it.
with osm_course as (
    select c.id as course_id, c.osm_polygons->'holes' as osm_holes
      from courses c
     where jsonb_array_length(coalesce(c.osm_polygons->'greens', '[]'::jsonb)) > 0
       and jsonb_array_length(coalesce(c.osm_polygons->'holes', '[]'::jsonb)) > 0
       and not exists (
             select 1 from jsonb_array_elements(c.osm_polygons->'holes') h
              where coalesce(h->>'ref', '') !~ '^[0-9]+$')
       and (select count(distinct (h->>'ref')::int) from jsonb_array_elements(c.osm_polygons->'holes') h)
           = jsonb_array_length(c.osm_polygons->'holes')
       and (select min((h->>'ref')::int) from jsonb_array_elements(c.osm_polygons->'holes') h) = 1
       and (select max((h->>'ref')::int) from jsonb_array_elements(c.osm_polygons->'holes') h)
           = jsonb_array_length(c.osm_polygons->'holes')
),
shared as (
    select h.id
      from holes h
      join osm_course oc on oc.course_id = h.course_id
     where exists (
             select 1 from jsonb_array_elements(oc.osm_holes) o
              where (o->>'ref')::int = h.number
                and abs((o->'greenPoint'->>'latitude')::float8 - h.latitude) < 1e-9
                and abs((o->'greenPoint'->>'longitude')::float8 - h.longitude) < 1e-9)
)
-- Personal: whoever placed it. First choice is the user whose round has this
-- exact placement for this hole number (most recent round first); then the
-- course's creator; then the most recent player of the course.
update holes h
   set owner_id = coalesce(
         (select r.user_id
            from rounds r
            join round_holes rh on rh.round_id = r.id and rh.number = h.number
           where r.course_id = h.course_id
             and abs(rh.latitude - h.latitude) < 1e-9
             and abs(rh.longitude - h.longitude) < 1e-9
           order by r.date desc
           limit 1),
         (select c.created_by from courses c where c.id = h.course_id),
         (select r.user_id from rounds r where r.course_id = h.course_id order by r.date desc limit 1))
 where h.id not in (select id from shared);

do $$
declare unresolved int;
begin
    select count(*) into unresolved
      from holes h
     where h.owner_id is null
       and not exists (
             select 1 from courses c, jsonb_array_elements(coalesce(c.osm_polygons->'holes', '[]'::jsonb)) o
              where c.id = h.course_id
                and o->>'ref' = h.number::text
                and abs((o->'greenPoint'->>'latitude')::float8 - h.latitude) < 1e-9
                and abs((o->'greenPoint'->>'longitude')::float8 - h.longitude) < 1e-9);
    if unresolved > 0 then
        raise exception 'holes ownership backfill: % non-OSM rows have no owner', unresolved;
    end if;
end $$;

alter table holes alter column owner_id set default auth.uid();
create index if not exists idx_holes_owner on holes(owner_id);

alter table holes drop constraint holes_course_id_number_key;
alter table holes add constraint holes_course_owner_number_key
    unique nulls not distinct (course_id, owner_id, number);

-- RLS. Read: shared rows and your own. Write: only your own.
drop policy if exists holes_read_all on holes;
drop policy if exists holes_insert_authenticated on holes;
drop policy if exists holes_update_authenticated on holes;
drop policy if exists holes_delete_authenticated on holes;

create policy holes_select_shared_or_own on holes
    for select to authenticated
    using (owner_id is null or owner_id = auth.uid());

create policy holes_insert_own on holes
    for insert to authenticated
    with check (owner_id = auth.uid());

create policy holes_update_own on holes
    for update to authenticated
    using (owner_id = auth.uid())
    with check (owner_id = auth.uid());

create policy holes_delete_own on holes
    for delete to authenticated
    using (owner_id = auth.uid());

revoke all on holes from anon;

-- Shared holes: built on the server from the course's own OSM data, and only
-- when its order is determined. Adds the numbers that have no shared row yet;
-- never moves or removes one. Returns how many it added.
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
      from courses where id = p_course_id;

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

-- A personal hole: the caller's row for (course, number), created or updated.
-- `p_id` names the row only when it is created and the id is free (the caller
-- may be editing the shared hole, whose id is taken). A null `p_par` keeps the
-- par the row already has. Returns the row's id.
create or replace function upsert_my_course_hole(
    p_id uuid,
    p_course_id uuid,
    p_number integer,
    p_latitude double precision,
    p_longitude double precision,
    p_par integer
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid uuid := auth.uid();
    v_id uuid;
begin
    if v_uid is null then
        raise exception 'not authenticated' using errcode = '42501';
    end if;

    select id into v_id from holes
     where course_id = p_course_id and owner_id = v_uid and number = p_number;

    if v_id is not null then
        update holes
           set latitude = p_latitude,
               longitude = p_longitude,
               par = coalesce(p_par, par),
               updated_at = now()
         where id = v_id;
        return v_id;
    end if;

    v_id := case
        when p_id is not null and not exists (select 1 from holes where id = p_id) then p_id
        else gen_random_uuid()
    end;
    insert into holes (id, course_id, owner_id, number, latitude, longitude, par, created_at, updated_at)
    values (v_id, p_course_id, v_uid, p_number, p_latitude, p_longitude, p_par, now(), now());
    return v_id;
end $$;

-- Removes the caller's own hole for (course, number). A shared hole for that
-- number is untouched.
create or replace function delete_my_course_hole(p_course_id uuid, p_number integer)
returns void
language sql
security invoker
set search_path = public
as $$
    delete from holes
     where course_id = p_course_id and owner_id = auth.uid() and number = p_number;
$$;

revoke execute on function derive_osm_course_holes(uuid) from public, anon;
revoke execute on function upsert_my_course_hole(uuid, uuid, integer, double precision, double precision, integer) from public, anon;
revoke execute on function delete_my_course_hole(uuid, integer) from public, anon;
grant execute on function derive_osm_course_holes(uuid) to authenticated;
grant execute on function upsert_my_course_hole(uuid, uuid, integer, double precision, double precision, integer) to authenticated;
grant execute on function delete_my_course_hole(uuid, integer) to authenticated;

commit;
