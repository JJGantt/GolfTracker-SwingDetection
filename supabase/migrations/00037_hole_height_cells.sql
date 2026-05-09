-- Per-hole height map: spatially-bucketed altitude cells in a shared frame.
--
-- Derived from `round_altitude_readings` via per-round client-side fold-in
-- at round end (see docs/ELEVATION_TRACKING.md, "Phase 1"). One row per
-- 3 m grid cell per hole. Each cell carries a weighted-mean altitude in
-- the hole's shared reference frame and a running sum of `sample_count`
-- across all contributing path-sample rows.
--
-- The quantization step is 3e-5 degrees (~3.3 m latitude, ~2.4-2.9 m
-- longitude at the latitudes of interest). Both client and server use
-- this same step when bucketing so cells align across rounds.
--
-- `hole_key` is "<course_id>:<hole_number>". Composite text keeps the
-- client lookup a single equality predicate. Different course rows that
-- happen to share physical geometry (multi-course resorts) get separate
-- hole_keys intentionally.
--
-- Writes happen exclusively through the `upsert_hole_height_cells`
-- function below, which uses row-level locking to serialize concurrent
-- fold-ins from multiple clients on the same hole. Reads are open to all
-- authenticated users (the height map is shared data — same as OSM
-- polygons in `osm_course_data`).

create table if not exists hole_height_cells (
    hole_key     text     not null,
    cell_lat     float8   not null,
    cell_lon     float8   not null,
    mean_alt_m   real     not null,
    n_samples    int4     not null,
    updated_at   timestamptz not null default now(),
    primary key (hole_key, cell_lat, cell_lon)
);

create index if not exists idx_hole_height_cells_hole
    on hole_height_cells(hole_key);

alter table hole_height_cells enable row level security;

-- Anyone authenticated can read the height map. It's shared, derived
-- data with no per-user privacy implications.
create policy hhc_select_all on hole_height_cells
    for select to authenticated using (true);

-- Direct writes are blocked. The fold-in function below (SECURITY
-- DEFINER) is the only path that can mutate this table.
revoke insert, update, delete on hole_height_cells from authenticated;

---------------------------------------------------------------------------
-- upsert_hole_height_cells: atomic merge for client-side fold-in.
--
-- Called by the device at round end, once per hole that had new path
-- samples. The client has already:
--   1. Pulled existing cells for this hole_key.
--   2. Solved a 1-variable weighted offset for the round (this round's
--      readings vs. the existing cells, via spatial crossings).
--   3. Applied the offset to all of its path samples on the hole.
--   4. Bucketed the corrected readings into 3 m cells, computing per
--      cell: weighted mean altitude (in the shared frame) and total
--      sample_count contributing.
--
-- This function takes those per-cell deltas, locks the affected rows
-- (SELECT ... FOR UPDATE inside the loop), and weighted-merges:
--     new_mean = (old_mean*old_n + delta_mean*delta_n) / (old_n + delta_n)
--     new_n    = old_n + delta_n
-- For cells with no existing row, the delta is inserted directly as the
-- seed.
--
-- The function runs in a single transaction and serializes concurrent
-- fold-ins on the same hole via row locks. Two clients finishing the
-- same hole at the same moment (rare but possible at a busy course)
-- will not lose updates.
--
-- `deltas` shape: jsonb array of objects, each with:
--     { "lat": float8, "lon": float8,
--       "mean_alt_m": float8, "n_samples": int4 }
-- `lat`/`lon` are already quantized cell centers from the client.
---------------------------------------------------------------------------

create or replace function upsert_hole_height_cells(
    p_hole_key text,
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
    if p_hole_key is null or length(p_hole_key) = 0 then
        raise exception 'hole_key required';
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
         where hole_key = p_hole_key
           and cell_lat = delta.cell_lat
           and cell_lon = delta.cell_lon
         for update;

        if existing_n is null then
            insert into hole_height_cells
                (hole_key, cell_lat, cell_lon, mean_alt_m, n_samples, updated_at)
            values
                (p_hole_key, delta.cell_lat, delta.cell_lon,
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
             where hole_key = p_hole_key
               and cell_lat = delta.cell_lat
               and cell_lon = delta.cell_lon;
        end if;

        existing_mean := null;
        existing_n    := null;
    end loop;
end;
$$;

revoke all on function upsert_hole_height_cells(text, jsonb) from public;
grant execute on function upsert_hole_height_cells(text, jsonb) to authenticated;
