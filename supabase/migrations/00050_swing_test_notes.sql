-- Notes for Swing Test Mode, kept OFF the swing tables.
--
-- A note is session-scoped and persistent: set once, it applies to every event
-- that occurs while it is active — detections, false-positive marks, and
-- lookback misses alike — until it is changed or cleared. It is not a per-swing
-- field, and regular round swings never have one, so it does not belong as a
-- column on swing_events. Instead each event is linked to the note that was
-- active when it was saved.

create table if not exists swing_test_notes (
    id              uuid primary key default gen_random_uuid(),
    user_id         uuid not null default auth.uid(),
    test_session_id uuid,                      -- soft ref, as elsewhere
    text            text not null,
    created_at      timestamptz not null default now()
);

-- One row per event saved while a note was active.
--   event_kind: 'swing_event' → swing_events.id (detections AND false positives —
--               a false positive is the same row with its label flipped)
--               'miss'        → false_negative_groups.id (a lookback capture)
create table if not exists swing_test_note_events (
    note_id    uuid not null references swing_test_notes(id) on delete cascade,
    event_kind text not null check (event_kind in ('swing_event', 'miss')),
    event_id   uuid not null,
    user_id    uuid not null default auth.uid(),
    created_at timestamptz not null default now(),
    primary key (note_id, event_kind, event_id)
);

create index if not exists idx_stne_event on swing_test_note_events(event_kind, event_id);

alter table swing_test_notes enable row level security;
alter table swing_test_note_events enable row level security;

create policy stn_owner_all on swing_test_notes
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy stne_owner_all on swing_test_note_events
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
