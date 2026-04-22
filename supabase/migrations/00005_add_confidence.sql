-- Add confidence column: 'high' (explicit user action) or 'low' (implicit flush)
alter table swing_events add column if not exists confidence text default 'low';
