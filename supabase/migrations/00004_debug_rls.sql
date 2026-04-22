-- Debug: check if RLS is the problem by temporarily disabling it
alter table swing_events disable row level security;
