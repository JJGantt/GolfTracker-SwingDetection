create or replace function public.whoami()
returns text
language sql
security definer
as $$
  select current_role::text;
$$;
