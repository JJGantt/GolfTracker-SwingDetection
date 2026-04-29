-- Lightweight per-device event log for diagnosing UI / sync timing issues
-- without needing console output. Apps fire-and-forget inserts at key
-- transitions; we query the table afterward to see where time was spent.
--
-- Intentionally simple: no constraints beyond user_id, no indexes beyond
-- the (user_id, occurred_at) read path we'll actually use.

create table if not exists client_events (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    device text not null,             -- "watch" / "phone"
    event text not null,              -- e.g. "addNextHole.start"
    detail jsonb,
    occurred_at timestamptz not null default now()
);

create index if not exists idx_client_events_user_time
    on client_events(user_id, occurred_at desc);

alter table client_events enable row level security;

drop policy if exists "ce_read_own" on client_events;
create policy "ce_read_own" on client_events
    for select to authenticated
    using (user_id = auth.uid());

drop policy if exists "ce_insert_own" on client_events;
create policy "ce_insert_own" on client_events
    for insert to authenticated
    with check (user_id = auth.uid());
