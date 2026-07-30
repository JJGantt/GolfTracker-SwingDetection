-- User-controlled club-type bag order.
--
-- The drag-to-reorder in ClubSetEditorView already existed but only mutated
-- the in-memory array — there was no persisted order, so the arrangement was
-- lost on the next SwiftData fetch and the list rendered in insertion order.
-- This column makes the user's order authoritative and syncs it across
-- devices, which also gives user-created club types a real position instead
-- of falling to the bottom of a distance-based sort.
--
-- Nullable: existing rows backfill on the client from the canonical
-- Drive -> Putt order the first time they load.

alter table public.club_types
  add column if not exists sort_order integer;

comment on column public.club_types.sort_order is
  '0-based position in the user''s bag order. Null means never arranged; the client backfills from the canonical default order.';
