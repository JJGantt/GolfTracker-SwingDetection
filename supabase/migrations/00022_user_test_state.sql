-- Cross-device test/simulation state. One row per user. The phone writes
-- to it from the developer Test Mode view; the watch (and the phone
-- itself) subscribe via Realtime postgres-changes and feed the simulated
-- coordinate into LocationManager when `enabled = true`.
--
-- Keeps GPS sim out-of-band from the regular play data so we don't have
-- to think about it polluting rounds, courses, etc.

create table if not exists user_test_state (
    user_id uuid primary key references auth.users(id) on delete cascade,
    enabled boolean not null default false,
    simulated_lat double precision,
    simulated_lon double precision,
    updated_at timestamptz not null default now()
);

alter table user_test_state enable row level security;

drop policy if exists "uts_own_select" on user_test_state;
create policy "uts_own_select" on user_test_state
    for select to authenticated
    using (user_id = auth.uid());

drop policy if exists "uts_own_insert" on user_test_state;
create policy "uts_own_insert" on user_test_state
    for insert to authenticated
    with check (user_id = auth.uid());

drop policy if exists "uts_own_update" on user_test_state;
create policy "uts_own_update" on user_test_state
    for update to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

drop policy if exists "uts_own_delete" on user_test_state;
create policy "uts_own_delete" on user_test_state
    for delete to authenticated
    using (user_id = auth.uid());
