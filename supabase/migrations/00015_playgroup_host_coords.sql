-- Add host GPS coordinates to playgroups so the join screen can filter
-- by proximity. Captured at host time from the host's current location;
-- joiners compare against their own current GPS.

alter table playgroups
    add column if not exists host_lat double precision,
    add column if not exists host_lon double precision;

create index if not exists idx_playgroups_host_coords
    on playgroups(host_lat, host_lon)
    where status = 'open';
