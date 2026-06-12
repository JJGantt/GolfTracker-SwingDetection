-- GPS horizontal accuracy (meters) captured per path sample.
--
-- Drives accuracy weighting in elevation calibration and fold-in: with
-- 3 m cells, only high-fidelity fixes can be trusted to land a sample
-- in the RIGHT cell. Weighting (client-side, ElevationFoldIn.accuracyFactor):
-- full weight at <= 5 m, linear taper to zero at 10 m, excluded beyond.
-- Null = legacy rows captured before this column existed (treated as a
-- middling 0.5 factor so the pre-existing map keeps working).
alter table public.round_altitude_readings
    add column if not exists h_acc real;
