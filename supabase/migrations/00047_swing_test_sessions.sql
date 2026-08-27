-- Swing Test Mode: a detector-tuning session with no round attached, plus
-- the label-semantics fix that makes its output trustworthy.
--
-- 1. PRACTICE SWINGS ARE NOT FALSE POSITIVES.
--
-- `label` answers one question: did the detector correctly identify a golf
-- swing? A practice swing is a YES. It is a real swing, correctly detected;
-- it just isn't a shot that counts toward the score. Until now the
-- practice-replacement path in `autoAddStrokeFromSwing` flipped those rows to
-- false_positive/high — the same call the undo button makes — which taught the
-- training set that correct detections of real swing motion were errors.
--
-- Worse, that action is the strongest true-positive signal the app produces:
-- it fires only when the user swung twice in the same spot without walking,
-- i.e. an unambiguous, attended, real swing. It was being captured, inverted,
-- and written in as a negative.
--
-- So the "didn't count as a shot" fact moves OUT of `label` and into its own
-- column. `label` stays a pure statement about detector correctness.
--
-- The existing false_positive rows are a blend of genuine misfires and
-- mislabeled practice swings and are deliberately NOT backfilled here — the
-- swing_events row records only `created_at` (detection time), never when the
-- label was flipped, so the two are indistinguishable from this table alone.
-- They ARE separable by joining `client_events` on the
-- `swing.update.falsePositive.ok` entries, which carry the event id and an
-- `occurred_at`: a practice replacement flips at the instant the NEXT
-- detection is created, an undo flips seconds-to-minutes later with no
-- detection alongside it. That join only reaches sessions where diagnostic
-- logging happened to be on before 2026-08-23, which is why this is left as a
-- manual exercise rather than a migration that would guess.

alter table swing_events
    add column if not exists not_a_stroke_reason text;

comment on column swing_events.not_a_stroke_reason is
    'Why a correctly-detected swing was not counted as a stroke. NULL = it counted. '
    '''practice'' = practice-swing replacement. Orthogonal to `label`, which only '
    'ever states whether the DETECTION was right.';

-- 2. TEST SESSIONS.
--
-- Swing Test Mode runs the detector exactly as a round does but starts no
-- round: no course, no holes, no strokes, no GPS requirement. Its detections
-- are still swing_events — same shape, same gates, same CSVs — so they live in
-- the same table and feed the same training set. `test_session_id` is the
-- provenance marker that makes them filterable, so round-only analysis is one
-- WHERE clause away rather than a second schema.

create table if not exists swing_test_sessions (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null default auth.uid(),
    started_at timestamptz not null default now(),
    ended_at timestamptz,
    notes text,
    detection_mode text default 'unifDetect',
    -- Counters as the watch saw them, so a session can be sanity-checked
    -- against its rows without trusting that every upload landed.
    detected_count int not null default 0,
    false_positive_count int not null default 0,
    lookback_count int not null default 0,
    created_at timestamptz not null default now()
);

create index if not exists idx_sts_user_started
    on swing_test_sessions(user_id, started_at desc);

alter table swing_test_sessions enable row level security;

create policy "sts_owner_read" on swing_test_sessions
    for select to authenticated
    using (user_id = auth.uid());
create policy "sts_owner_insert" on swing_test_sessions
    for insert to authenticated
    with check (user_id = auth.uid());
create policy "sts_owner_update" on swing_test_sessions
    for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- Soft reference, matching the `stroke_id` precedent set in 00030: the watch
-- inserts the session row and its first swing_events row back to back over an
-- eventually-consistent write path, and a hard FK turns a slow session insert
-- into a lost detection.
alter table swing_events
    add column if not exists test_session_id uuid;

create index if not exists idx_swing_events_test_session
    on swing_events(test_session_id) where test_session_id is not null;

comment on column swing_events.test_session_id is
    'Set when the detection came from Swing Test Mode rather than a round. '
    'NULL for round play. Soft reference to swing_test_sessions(id).';

-- 3. LOOKBACK CAPTURES — the miss that leaves no trace.
--
-- `false_negative_groups` currently only ever describes one thing: the user
-- added a stroke by hand, so we shipped every post-pairing rejection since the
-- last stroke as candidates for the swing that was missed. That covers a miss
-- the detector ALMOST caught — setup, backswing top and follow-through peak
-- all paired, and a contact gate then killed it.
--
-- It cannot cover the worse miss. `recordRejection` is reachable only from the
-- post-pairing gates, so when a swing fails earlier — no setup event, no
-- valley or peak of sufficient prominence, or pairing blocked by an intervening
-- event — nothing is recorded anywhere, `rejections` is empty, and the upload
-- early-returns. The class of miss that is hardest to reconstruct after the
-- fact is precisely the one that generates no data.
--
-- The lookback button fixes that by dumping the raw rolling buffer, which
-- already retains 180s of 100Hz device motion while monitoring. A group can now
-- carry a raw window CSV of its own, so it stands on its own with zero
-- candidates attached.
alter table false_negative_groups
    add column if not exists capture_reason text not null default 'rejected_shapes';

alter table false_negative_groups
    add column if not exists storage_path text;

alter table false_negative_groups
    add column if not exists test_session_id uuid;

alter table false_negative_groups
    add column if not exists window_seconds double precision;

comment on column false_negative_groups.capture_reason is
    '''rejected_shapes'' = manual stroke add; candidates are the post-pairing '
    'rejections since the last stroke. ''lookback'' = the user pressed Missed It; '
    '`storage_path` holds the raw motion window and candidate_count may be 0, '
    'which is itself the finding — nothing even paired.';

comment on column false_negative_groups.storage_path is
    'Raw motion-window CSV for a ''lookback'' capture. NULL for '
    '''rejected_shapes'' groups, whose motion lives per-candidate instead.';

comment on column false_negative_groups.window_seconds is
    'Actual span of a lookback capture. Shorter than the 15s maximum whenever a '
    'detection or an earlier capture already covered the ground behind it.';
