-- Hisaably — Phase 3: authorization helpers, read grants, RLS policies
--
-- Model:
--   * Clients (role `authenticated`) get SELECT only; RLS decides which rows.
--   * ALL writes go through SECURITY DEFINER RPCs (next migrations), which
--     check permissions explicitly. Clients have no INSERT/UPDATE/DELETE on
--     any table, so role/status escalation via direct writes is impossible.
--   * `anon` gets nothing.
--   * A DISABLED profile, a DISABLED membership or a DISABLED group all remove
--     access immediately (checked on every call, independent of the JWT).
--   * SUPER_ADMIN (ACTIVE) can read everything, including disabled groups.

-- ---------------------------------------------------------------------------
-- Error helper: app errors carry a machine-readable code in HINT.
-- ---------------------------------------------------------------------------
create function public.raise_app_error(p_code text, p_message text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using message = p_message, hint = p_code, errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------------
-- Identity / permission helpers (SECURITY DEFINER so they can read the
-- membership tables without RLS recursion; they only reveal facts about the
-- caller).
-- ---------------------------------------------------------------------------
create function public.auth_profile_active()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and status = 'ACTIVE'
  );
$$;

create function public.is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'SUPER_ADMIN' and status = 'ACTIVE'
  );
$$;

create function public.is_group_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members gm
    join public.groups g on g.id = gm.group_id
    join public.profiles p on p.id = gm.user_id
    where gm.group_id = p_group_id
      and gm.user_id = auth.uid()
      and gm.status = 'ACTIVE'
      and g.status = 'ACTIVE'
      and p.status = 'ACTIVE'
  );
$$;

create function public.is_group_admin(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members gm
    join public.groups g on g.id = gm.group_id
    join public.profiles p on p.id = gm.user_id
    where gm.group_id = p_group_id
      and gm.user_id = auth.uid()
      and gm.group_role = 'GROUP_ADMIN'
      and gm.status = 'ACTIVE'
      and g.status = 'ACTIVE'
      and p.status = 'ACTIVE'
  );
$$;

create function public.can_view_group(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_super_admin() or public.is_group_member(p_group_id);
$$;

create function public.can_manage_group(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_super_admin() or public.is_group_admin(p_group_id);
$$;

-- True if the caller and p_user_id are both in some group the caller can see
-- (used to show member names inside a group).
create function public.shares_group_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members other
    where other.user_id = p_user_id
      and public.is_group_member(other.group_id)
  );
$$;

-- Guard used at the top of every RPC.
create function public.require_active_user()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    perform public.raise_app_error('NOT_AUTHENTICATED', 'Please sign in again.');
  end if;
  if not public.auth_profile_active() then
    perform public.raise_app_error('ACCOUNT_DISABLED', 'Your account has been disabled.');
  end if;
  return v_uid;
end;
$$;

create function public.require_super_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_active_user();
begin
  if not public.is_super_admin() then
    perform public.raise_app_error('FORBIDDEN', 'Only the Super Admin can do this.');
  end if;
  return v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Read grants (RLS filters the rows)
-- ---------------------------------------------------------------------------
grant select on public.profiles,
                public.groups,
                public.group_members,
                public.group_categories,
                public.transactions,
                public.monthly_summaries,
                public.notification_devices,
                public.notifications
  to authenticated;

grant execute on function public.auth_profile_active(),
                          public.is_super_admin(),
                          public.is_group_member(uuid),
                          public.is_group_admin(uuid),
                          public.can_view_group(uuid),
                          public.can_manage_group(uuid),
                          public.shares_group_with(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- RLS policies (SELECT only)
-- ---------------------------------------------------------------------------
-- Own profile is always readable (even when DISABLED) so the app can show
-- "Your account has been disabled".
create policy profiles_select on public.profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or (select public.is_super_admin())
    or public.shares_group_with(id)
  );

create policy groups_select on public.groups
  for select to authenticated
  using (public.can_view_group(id));

create policy group_members_select on public.group_members
  for select to authenticated
  using (public.can_view_group(group_id));

create policy group_categories_select on public.group_categories
  for select to authenticated
  using (public.can_view_group(group_id));

create policy transactions_select on public.transactions
  for select to authenticated
  using (public.can_view_group(group_id));

create policy monthly_summaries_select on public.monthly_summaries
  for select to authenticated
  using (public.can_view_group(group_id));

create policy notification_devices_select on public.notification_devices
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy notifications_select on public.notifications
  for select to authenticated
  using (
    recipient_id = (select auth.uid())
    and (select public.auth_profile_active())
  );
