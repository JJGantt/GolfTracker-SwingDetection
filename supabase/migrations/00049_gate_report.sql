-- Per-gate verdicts on every detection, passes included.
--
-- `false_negative_candidates.gate_fails` only ever described rejections, so a
-- detection that squeaked through carried its raw values and nothing else.
-- Reading "did this barely pass, and on which gate" meant fetching the
-- thresholds separately and doing the arithmetic by hand.
--
-- Shape: { "<gate>": { "value", "limit", "margin", "passed" } } — margin is
-- positive when passing and says by how much in the gate's own units.
alter table swing_events
    add column if not exists gate_report jsonb;

comment on column swing_events.gate_report is
    'Per-gate value/limit/margin/passed at detection time. NULL before build 68.';
