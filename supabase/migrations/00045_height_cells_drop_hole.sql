-- Drop the hole number from the height map's identity.
--
-- WHY
--
-- Migration 00037 created this table as a "per-hole height map", and its own
-- header says why: each cell held "a weighted-mean altitude in the hole's
-- shared reference frame". That was accurate then. The client fold-in solved
-- one constant offset per round PER HOLE, so hole 3's heights and hole 12's
-- heights sat in unrelated frames and mixing them would have been meaningless.
-- The hole number was not a label on a cell; it was which datum the number
-- lived in, and it was load-bearing.
--
-- Migration 00044 removed that. The global re-solve works on the whole course
-- at once, so there is now ONE datum per course, and it does not consult hole
-- labels. The reason for the hole in the key died with 00044; the schema kept
-- it.
--
-- WHAT IT COSTS TO KEEP
--
-- `hole_number` on a reading is not survey data. It is whatever hole the app
-- happened to be counting when the sample was captured, set by
-- AutoAdvanceMonitor, whose triggers B and C fire on proximity to the next
-- hole's centerline or to a historical first-stroke spot with no putt gate.
-- When it advances early, the readings keep landing on the right ground and
-- get filed at the wrong address.
--
-- Measured on live data at the time of writing: at Hyde Park every reading on
-- hole 15's green carries the label 16, so a lookup at hole 15 finds nothing
-- while hole 16 carries a phantom blob 144 m from its own green. Worse, since
-- `hole_key` is part of the PRIMARY KEY, the same 3 m square can exist twice
-- under two holes with two different heights. 14 such squares exist across the
-- two mapped courses, disagreeing by up to 4.61 m where the true difference is
-- zero by construction, and neither copy carries the full sample count.
--
-- WHAT REPLACES IT
--
-- Cells are addressed by (course_id, cell_lat, cell_lon). The map is one
-- elevation surface per course. The hole number stays where it belongs: as UI
-- state naming the hole currently in focus, used to pick which green centroid
-- from `holes` the yardage is measured to. The math never sees it.
--
-- This migration is destructive in one respect: duplicate squares are merged
-- by weighted mean and the losing rows are gone. That is the correct answer
-- (they describe the same ground and should always have been one row), but it
-- cannot be undone from this table. `round_altitude_readings` is retained in
-- full, so the map remains rebuildable from raw by the resolve function.

begin;

alter table hole_height_cells add column if not exists course_id uuid;

update hole_height_cells
   set course_id = split_part(hole_key, ':', 1)::uuid
 where course_id is null;

-- Any row whose hole_key doesn't parse to a real course has no addressable
-- home under the new scheme. There should be none; fail loudly if there are.
do $$
declare orphans int;
begin
    select count(*) into orphans
      from hole_height_cells h
     where h.course_id is null
        or not exists (select 1 from courses c where c.id = h.course_id);
    if orphans > 0 then
        raise exception 'hole_height_cells has % rows whose hole_key does not resolve to a course', orphans;
    end if;
end $$;

-- Merge squares that existed once per hole into one row per square.
-- Weighted by n_samples, which is exactly what upsert_hole_height_cells would
-- have produced had the rows never been split.
create temp table hhc_merged on commit drop as
select course_id,
       cell_lat,
       cell_lon,
       (sum(mean_alt_m::float8 * n_samples) / nullif(sum(n_samples), 0))::real as mean_alt_m,
       sum(n_samples)::int4 as n_samples,
       max(updated_at)      as updated_at
  from hole_height_cells
 group by course_id, cell_lat, cell_lon;

delete from hole_height_cells;

alter table hole_height_cells drop constraint if exists hole_height_cells_pkey;
drop index if exists idx_hole_height_cells_hole;
alter table hole_height_cells drop column if exists hole_key;
alter table hole_height_cells alter column course_id set not null;
alter table hole_height_cells
    add constraint hole_height_cells_pkey primary key (course_id, cell_lat, cell_lon);
alter table hole_height_cells
    add constraint hole_height_cells_course_fk
    foreign key (course_id) references courses(id) on delete cascade;

insert into hole_height_cells (course_id, cell_lat, cell_lon, mean_alt_m, n_samples, updated_at)
select course_id, cell_lat, cell_lon, mean_alt_m, n_samples, updated_at from hhc_merged;

create index if not exists idx_hole_height_cells_course
    on hole_height_cells(course_id);

comment on table hole_height_cells is
  'Shared elevation map, one row per 3 m cell per COURSE, in that course''s single datum. Addressed by position only — the hole number a reading carried is app UI state (AutoAdvanceMonitor), not survey data, and was removed in 00045.';
comment on column hole_height_cells.course_id is
  'Owning course. Replaced hole_key in 00045; see that migration for why the hole number was load-bearing under the per-hole frame model and became a liability under the course-wide one.';

---------------------------------------------------------------------------
-- upsert_course_height_cells: atomic merge for client fold-in.
--
-- Same weighted merge as the old upsert_hole_height_cells, addressed by course
-- rather than hole. The client now folds a round in ONCE for the whole course
-- instead of once per hole.
---------------------------------------------------------------------------

create or replace function upsert_course_height_cells(
    p_course_id uuid,
    p_deltas jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    delta record;
    existing_mean real;
    existing_n    int4;
    merged_mean   real;
    merged_n      int4;
begin
    if p_course_id is null then
        raise exception 'course_id required';
    end if;
    if not exists (select 1 from courses where id = p_course_id) then
        raise exception 'unknown course %', p_course_id;
    end if;
    if p_deltas is null or jsonb_array_length(p_deltas) = 0 then
        return;
    end if;

    for delta in
        select
            (elem->>'lat')::float8        as cell_lat,
            (elem->>'lon')::float8        as cell_lon,
            (elem->>'mean_alt_m')::float8 as delta_mean,
            (elem->>'n_samples')::int4    as delta_n
        from jsonb_array_elements(p_deltas) as elem
    loop
        if delta.delta_n is null or delta.delta_n <= 0 then
            continue;
        end if;

        select mean_alt_m, n_samples
          into existing_mean, existing_n
          from hole_height_cells
         where course_id = p_course_id
           and cell_lat  = delta.cell_lat
           and cell_lon  = delta.cell_lon
         for update;

        if existing_n is null then
            insert into hole_height_cells
                (course_id, cell_lat, cell_lon, mean_alt_m, n_samples, updated_at)
            values
                (p_course_id, delta.cell_lat, delta.cell_lon,
                 delta.delta_mean, delta.delta_n, now());
        else
            merged_n    := existing_n + delta.delta_n;
            merged_mean := (existing_mean::float8 * existing_n
                          + delta.delta_mean * delta.delta_n)
                         / merged_n::float8;

            update hole_height_cells
               set mean_alt_m = merged_mean,
                   n_samples  = merged_n,
                   updated_at = now()
             where course_id = p_course_id
               and cell_lat  = delta.cell_lat
               and cell_lon  = delta.cell_lon;
        end if;
    end loop;
end $$;

revoke all on function upsert_course_height_cells(uuid, jsonb) from public;
grant execute on function upsert_course_height_cells(uuid, jsonb) to authenticated;

comment on function upsert_course_height_cells(uuid, jsonb) is
  'Weighted merge of client fold-in deltas into one course''s height map. Cells are addressed by position only. Replaced upsert_hole_height_cells in 00045.';

drop function if exists upsert_hole_height_cells(text, jsonb);

---------------------------------------------------------------------------
-- replace_course_height_cells: wholesale rebuild from the global re-solve.
-- Same contract as 00044's replace_hole_height_cells, minus hole_number.
---------------------------------------------------------------------------

create or replace function replace_course_height_cells(
    p_course_id uuid,
    p_cells jsonb
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
    written int;
begin
    if p_course_id is null then
        raise exception 'course_id required';
    end if;
    if p_cells is null or jsonb_array_length(p_cells) = 0 then
        raise exception 'refusing to replace a course map with an empty set';
    end if;

    delete from hole_height_cells where course_id = p_course_id;

    insert into hole_height_cells
        (course_id, cell_lat, cell_lon, mean_alt_m, n_samples, updated_at)
    select p_course_id,
           (elem->>'lat')::float8,
           (elem->>'lon')::float8,
           (elem->>'mean_alt_m')::float8,
           (elem->>'n_samples')::int4,
           now()
      from jsonb_array_elements(p_cells) as elem;

    get diagnostics written = row_count;
    return written;
end $$;

revoke all on function replace_course_height_cells(uuid, jsonb) from public;
revoke all on function replace_course_height_cells(uuid, jsonb) from authenticated;

comment on function replace_course_height_cells(uuid, jsonb) is
  'Wholesale rebuild of one course''s height map from a global re-solve. Service role only; use upsert_course_height_cells for incremental client fold-in. Replaced replace_hole_height_cells in 00045.';

drop function if exists replace_hole_height_cells(uuid, jsonb);

commit;
