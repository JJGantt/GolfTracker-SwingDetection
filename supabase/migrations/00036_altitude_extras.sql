-- Per-stroke barometric reading + per-sample averaging count.
--
-- 1. `strokes.rel_alt_meters` — altimeter reading at the moment a stroke
--    was recorded. Within a single round these values are referenced to
--    the same anchor (whatever the altimeter happened to be at when
--    `startRelativeAltitudeUpdates` fired on round start), so deltas
--    between strokes on the same hole are drift-free under ~50cm. Lets
--    us bake actual elevation change into per-club distance stats
--    without going through the cross-user height-map model.
--
-- 2. `round_altitude_readings.sample_count` — number of altimeter
--    callbacks that were averaged into this row. Single-reading rows
--    (user walking past) get 1; rows captured while standing still get
--    many. The modeling layer can weight observations by this count.

alter table strokes
    add column if not exists rel_alt_meters real;

alter table round_altitude_readings
    add column if not exists sample_count int2 not null default 1;
