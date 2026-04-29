-- Fix infinite-recursion error on `playgroup_members` RLS policy.
--
-- The original `pm_read_co_members` policy from migration 00014 had a
-- self-referential subquery:
--
--     using (
--         user_id = auth.uid()
--         or exists (
--             select 1 from playgroup_members pm2
--             where pm2.playgroup_id = playgroup_members.playgroup_id
--               and pm2.user_id = auth.uid()
--         )
--     )
--
-- The inner `select … from playgroup_members pm2` is itself subject to
-- RLS, which re-applies pm_read_co_members, which contains the same
-- subquery, which re-applies again, etc. Postgres aborts with
-- "infinite recursion detected in policy".
--
-- The clean fix: a SECURITY DEFINER function that runs with elevated
-- privileges, bypassing RLS for the membership check. The function reads
-- playgroup_members directly without triggering the recursive policy.
-- We then rewrite policies that need the membership check to call the
-- function.

create or replace function public.is_playgroup_member(pg_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
    select exists (
        select 1 from playgroup_members
        where playgroup_id = pg_id
          and user_id = auth.uid()
    );
$$;

-- Allow authenticated callers to invoke the function. SECURITY DEFINER
-- means it runs with the function owner's privileges (postgres / service
-- role), so the inner SELECT bypasses RLS regardless of caller.
revoke all on function public.is_playgroup_member(uuid) from public;
grant execute on function public.is_playgroup_member(uuid) to authenticated;

-- Replace the recursive policy on playgroup_members.
drop policy if exists "pm_read_co_members" on playgroup_members;
create policy "pm_read_co_members" on playgroup_members
    for select to authenticated
    using (
        user_id = auth.uid()
        or public.is_playgroup_member(playgroup_id)
    );

-- The original playgroups_read_member policy queries playgroup_members
-- in a subquery. With the fixed pm_read_co_members it would no longer
-- recurse, but using the function directly is simpler + faster.
drop policy if exists "playgroups_read_member" on playgroups;
create policy "playgroups_read_member" on playgroups
    for select to authenticated
    using (
        host_id = auth.uid()
        or public.is_playgroup_member(id)
    );
