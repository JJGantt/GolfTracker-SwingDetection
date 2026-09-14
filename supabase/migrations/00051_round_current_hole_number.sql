-- Which hole a round is on, as the hole NUMBER.
--
-- current_hole_index was a position in each device's own sorted hole list, and
-- the two devices' lists could differ (the phone could hold a course's holes
-- twice), so one index named different holes on the phone and the watch. A
-- number names the same hole everywhere. Builds from this one read and write
-- current_hole_number only; current_hole_index is left in place for older
-- builds and is not read by newer ones.
alter table rounds add column if not exists current_hole_number integer;

-- Backfill from the round's own holes: the index-th hole by number, or
-- index + 1 when the round has fewer hole rows than that.
update rounds r
set current_hole_number = coalesce(
    (select rh.number
       from round_holes rh
      where rh.round_id = r.id
      order by rh.number
     offset greatest(r.current_hole_index, 0)
      limit 1),
    greatest(r.current_hole_index, 0) + 1)
where r.current_hole_number is null;

-- Keep both columns naming the same hole whichever one a client wrote, so an
-- older build (index only) and a newer one (number only) stay in step while
-- the phone and watch update at different times.
create or replace function rounds_sync_current_hole() returns trigger
language plpgsql as $$
begin
    if tg_op = 'INSERT' then
        if new.current_hole_number is null then
            new.current_hole_number := greatest(new.current_hole_index, 0) + 1;
        end if;
        return new;
    end if;
    if new.current_hole_number is distinct from old.current_hole_number then
        new.current_hole_index := (select count(*) from round_holes rh
                                    where rh.round_id = new.id
                                      and rh.number < new.current_hole_number);
    elsif new.current_hole_index is distinct from old.current_hole_index then
        new.current_hole_number := coalesce(
            (select rh.number
               from round_holes rh
              where rh.round_id = new.id
              order by rh.number
             offset greatest(new.current_hole_index, 0)
              limit 1),
            greatest(new.current_hole_index, 0) + 1);
    end if;
    return new;
end;
$$;

drop trigger if exists rounds_sync_current_hole on rounds;
create trigger rounds_sync_current_hole
    before insert or update on rounds
    for each row execute function rounds_sync_current_hole();
