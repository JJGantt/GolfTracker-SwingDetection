-- Normalize `hole_height_cells.hole_key` to lowercase, permanently.
--
-- The key is "<course_id>:<hole_number>". Swift's `UUID.uuidString` is always
-- UPPERCASE; Postgres renders uuid as lowercase. A service-role backfill on
-- 2026-06-12 re-inserted Wekiva's cells using ids read back from the database,
-- producing a second, lowercased copy of all 472 cells:
--
--     D133B094-045A-49FE-B4E5-ACD60614C7C1:*   472 cells, 1705 samples
--     d133b094-045a-49fe-b4e5-acd60614c7c1:*   472 cells, 1705 samples
--
-- Verified byte-for-byte identical (same 472 (hole, cell) keys, zero differing
-- values), so this is a duplicate rather than lost data — the client only ever
-- reads the uppercase half and that half is complete.
--
-- The latent hazard is what happens next: `upsert_hole_height_cells` merges on
-- hole_key, so any future write using the other casing accumulates into a
-- namespace the client never reads, and THAT would silently lose real data.
--
-- Fix in three parts:
--   1. Drop the duplicate lowercase rows (do NOT weighted-merge them — they're
--      a copy, not independent observations; merging would double n_samples
--      and corrupt the means).
--   2. Lowercase every remaining key.
--   3. Make it structural: normalize inside the RPC (the only write path, since
--      direct DML is revoked) and add a CHECK so nothing can reintroduce a
--      mixed-case key.

-- 1. Remove rows that would collide once lowercased.
--
--    Deletes ONLY a mixed-case row that already has an all-lowercase twin at
--    the same cell. Single predicate, no OR — the version first applied here
--    used `(A and B) or C`, and because AND binds tighter than OR the two
--    branches matched OPPOSITE members of each pair (branch one deleted the
--    uppercase row, branch two deleted the newer row, which was the lowercase
--    one). Both rows satisfied a branch, so both were deleted and Wekiva's
--    entire 472-cell map was destroyed rather than just its duplicate.
--
--    hole_height_cells is derived from round_altitude_readings, which was
--    untouched, so that map simply reseeds on the next round played there.
--    Any future delete in a migration gets run as a SELECT first.
delete from hole_height_cells a
where a.hole_key <> lower(a.hole_key)
  and exists (
      select 1
        from hole_height_cells b
       where b.hole_key = lower(a.hole_key)
         and b.cell_lat = a.cell_lat
         and b.cell_lon = a.cell_lon
  );

-- 2. Normalize the survivors.
update hole_height_cells
   set hole_key = lower(hole_key)
 where hole_key <> lower(hole_key);

-- 3a. Structural guard.
alter table hole_height_cells
    drop constraint if exists hole_height_cells_hole_key_lower;
alter table hole_height_cells
    add constraint hole_height_cells_hole_key_lower
    check (hole_key = lower(hole_key));

comment on column hole_height_cells.hole_key is
  'lower("<course_id>:<hole_number>"). Lowercase is enforced by CHECK and normalized inside upsert_hole_height_cells — Swift uuidString is uppercase, Postgres uuid is lowercase, and letting both in split the map.';

-- 3b. Normalize at the only write path. Direct INSERT/UPDATE/DELETE is revoked
--     from authenticated, so this function is the sole way rows are created;
--     lowercasing here means a caller passing either casing lands in one place.
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
    v_hole_key    text;
begin
    if p_hole_key is null or length(p_hole_key) = 0 then
        raise exception 'hole_key required';
    end if;
    -- Single normalization point for the whole table.
    v_hole_key := lower(p_hole_key);
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
         where hole_key = v_hole_key
           and cell_lat = delta.cell_lat
           and cell_lon = delta.cell_lon
         for update;

        if existing_n is null then
            insert into hole_height_cells
                (hole_key, cell_lat, cell_lon, mean_alt_m, n_samples, updated_at)
            values
                (v_hole_key, delta.cell_lat, delta.cell_lon,
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
             where hole_key = v_hole_key
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
