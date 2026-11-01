-- Global re-solve of a course's height map from raw path samples.
--
-- `hole_height_cells` is currently only ever built by the client's greedy
-- fold-in (ElevationFoldIn): the first round on a hole seeds the frame, every
-- later round solves ONE offset against the accumulated cells, and the result
-- is merged into a running weighted mean. That has three costs:
--
--   1. Each hole is an independent frame. Nothing ties hole 3's datum to
--      hole 12's, and a spatial crossing between two rounds playing DIFFERENT
--      holes (adjacent green/tee, shared cart path) is discarded outright.
--   2. A round that crosses nothing on a hole is dropped (`isUncalibrated`),
--      even when its altimeter frame is fully determined by its crossings on
--      other holes of the same round.
--   3. Merges are irreversible. A bad seed, or an offset solved against a bad
--      seed, is permanent — the running mean can't be un-merged.
--
-- The `resolve-hole-heights` edge function fixes all three by re-deriving the
-- map from `round_altitude_readings`, which is retained in full, and then
-- rebuilding the course's cells.
--
-- This migration adds the two things that function needs and the client path
-- can't provide: a wholesale replace (the existing RPC only merges) and an
-- audit row so a map's provenance and residual are inspectable after the fact.

---------------------------------------------------------------------------
-- Audit trail: one row per re-solve.
---------------------------------------------------------------------------
create table if not exists hole_height_solves (
    id                uuid primary key default gen_random_uuid(),
    course_id         uuid not null references courses(id) on delete cascade,
    solved_at         timestamptz not null default now(),
    rounds_used       int4     not null,
    rounds_excluded   int4     not null,
    readings_used     int4     not null,
    crossings_used    int4     not null,
    unknowns          int4     not null,
    knot_minutes      real     not null,
    lambda            real     not null,
    -- Residuals of the solve, metres.
    rms_meters        real     not null,
    rms_constant      real     not null,
    cells_written     int4     not null,
    detail            jsonb,
    created_at        timestamptz not null default now()
);

create index if not exists idx_hole_height_solves_course
    on hole_height_solves(course_id, solved_at desc);

alter table hole_height_solves enable row level security;

-- Readable by anyone authenticated, same as the height map it describes.
-- Written only by the edge function under the service role.
create policy hhs_select_all on hole_height_solves
    for select to authenticated using (true);

revoke insert, update, delete on hole_height_solves from authenticated;

---------------------------------------------------------------------------
-- replace_hole_height_cells: atomic wholesale rebuild for one course.
--
-- `upsert_hole_height_cells` merges, which is right for the incremental
-- client path and wrong here: a re-solve's output already accounts for every
-- reading, so merging it into the old cells would double-count every sample
-- and blend two different frames. This deletes the course's cells and inserts
-- the new set in a single transaction.
--
-- Scoping is by hole_key prefix. hole_key is "<course_id>:<hole_number>" and
-- migration 00043 made lowercase the enforced normal form, so a lowercased
-- uuid followed by ':' is an exact, unambiguous prefix (uuid text is fixed
-- width, and ':' can't appear inside one).
--
-- `p_cells` shape: jsonb array of
--     { "hole_number": int, "lat": float8, "lon": float8,
--       "mean_alt_m": float8, "n_samples": int4 }
-- lat/lon are already-quantized cell centers from the caller, using the same
-- 3e-5 degree step as ElevationFoldIn.cellStepDeg.
--
-- An empty `p_cells` is rejected rather than treated as "delete everything".
-- A solver that fails to produce cells is a bug, and this is the one call in
-- the system that can destroy a course's map — migration 00043 already lost
-- Wekiva's 472 cells to a delete whose predicate matched more than intended.
---------------------------------------------------------------------------
create or replace function replace_hole_height_cells(
    p_course_id uuid,
    p_cells jsonb
) returns int4
language plpgsql
security definer
set search_path = public
as $$
declare
    v_prefix text;
    v_count  int4;
begin
    if p_course_id is null then
        raise exception 'course_id required';
    end if;
    if p_cells is null or jsonb_array_length(p_cells) = 0 then
        raise exception 'refusing to replace with an empty cell set';
    end if;

    v_prefix := lower(p_course_id::text) || ':';

    delete from hole_height_cells where hole_key like v_prefix || '%';

    insert into hole_height_cells
        (hole_key, cell_lat, cell_lon, mean_alt_m, n_samples, updated_at)
    select
        v_prefix || (elem->>'hole_number'),
        (elem->>'lat')::float8,
        (elem->>'lon')::float8,
        (elem->>'mean_alt_m')::float8,
        (elem->>'n_samples')::int4,
        now()
      from jsonb_array_elements(p_cells) as elem
     where (elem->>'n_samples')::int4 > 0;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

-- Service role only. This is a destructive rebuild, not something a client
-- should be able to trigger with a user JWT.
revoke all on function replace_hole_height_cells(uuid, jsonb) from public;
revoke all on function replace_hole_height_cells(uuid, jsonb) from authenticated;

comment on function replace_hole_height_cells(uuid, jsonb) is
  'Wholesale rebuild of one course''s hole_height_cells from a global re-solve. Service role only; use upsert_hole_height_cells for incremental client fold-in.';
