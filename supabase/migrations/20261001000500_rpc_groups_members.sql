-- Hisaably — Phase 3: context, group and membership RPCs
--
-- Permission summary (owner decisions override the spec where noted):
--   create_group / set_group_status          SUPER_ADMIN
--   rename_group                             SUPER_ADMIN or that group's GROUP_ADMIN
--   add_group_member / remove_group_member   SUPER_ADMIN only
--   set_group_member_role                    SUPER_ADMIN only (assign/remove Group Admin)
--   set_group_member_status                  SUPER_ADMIN; or GROUP_ADMIN of that group for
--                                            plain MEMBERS other than themselves
--                                            (Group Admins can't remove anyone — decision 9)
--   update_user_name                         SUPER_ADMIN
-- User create/reset-password/disable/enable/delete need Supabase Auth admin
-- APIs, so they live in the `admin-users` Edge Function.

-- ---------------------------------------------------------------------------
-- Caller context for routing: profile + memberships. Works for DISABLED
-- users too (returns their status) so the app can explain why access is blocked.
-- ---------------------------------------------------------------------------
create function public.get_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null then
    perform public.raise_app_error('NOT_AUTHENTICATED', 'Please sign in again.');
  end if;

  select jsonb_build_object(
    'profile', jsonb_build_object(
      'id', p.id, 'name', p.name, 'username', p.username,
      'role', p.role, 'status', p.status
    ),
    'memberships', coalesce((
      select jsonb_agg(jsonb_build_object(
        'group_id', g.id,
        'group_name', g.name,
        'group_status', g.status,
        'group_role', gm.group_role,
        'membership_status', gm.status
      ) order by lower(g.name))
      from public.group_members gm
      join public.groups g on g.id = gm.group_id
      where gm.user_id = p.id
    ), '[]'::jsonb)
  )
  into v_result
  from public.profiles p
  where p.id = v_uid;

  if v_result is null then
    perform public.raise_app_error('NOT_FOUND', 'Your profile could not be found.');
  end if;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Groups
-- ---------------------------------------------------------------------------
create function public.normalize_name(p_name text, p_max integer, p_label text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if v = '' then
    perform public.raise_app_error('VALIDATION', p_label || ' is required.');
  end if;
  if char_length(v) > p_max then
    perform public.raise_app_error(
      'VALIDATION', format('%s must be at most %s characters.', p_label, p_max));
  end if;
  return v;
end;
$$;

create function public.create_group(p_name text)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.groups;
begin
  perform public.require_super_admin();
  insert into public.groups (name)
  values (public.normalize_name(p_name, 60, 'Group name'))
  returning * into v_row;
  return v_row;
end;
$$;

create function public.rename_group(p_group_id uuid, p_name text)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.groups;
begin
  perform public.require_active_user();
  if not public.can_manage_group(p_group_id) then
    perform public.raise_app_error('FORBIDDEN', 'You cannot rename this group.');
  end if;
  update public.groups
     set name = public.normalize_name(p_name, 60, 'Group name')
   where id = p_group_id
  returning * into v_row;
  if v_row.id is null then
    perform public.raise_app_error('NOT_FOUND', 'Group not found.');
  end if;
  return v_row;
end;
$$;

create function public.set_group_status(p_group_id uuid, p_status public.record_status)
returns public.groups
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.groups;
begin
  perform public.require_super_admin();
  update public.groups set status = p_status where id = p_group_id
  returning * into v_row;
  if v_row.id is null then
    perform public.raise_app_error('NOT_FOUND', 'Group not found.');
  end if;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- Members
-- ---------------------------------------------------------------------------
create function public.add_group_member(
  p_group_id uuid,
  p_user_id uuid,
  p_group_role public.group_role default 'MEMBER'
)
returns public.group_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group  public.groups;
  v_status public.record_status;
  v_active integer;
  v_row    public.group_members;
begin
  perform public.require_super_admin();

  -- Lock the group row: serializes concurrent adds for this group (10-member race).
  select * into v_group from public.groups where id = p_group_id for update;
  if v_group.id is null then
    perform public.raise_app_error('NOT_FOUND', 'Group not found.');
  end if;
  if v_group.status <> 'ACTIVE' then
    perform public.raise_app_error('GROUP_DISABLED', 'This group is disabled.');
  end if;

  select status into v_status from public.profiles where id = p_user_id;
  if v_status is null then
    perform public.raise_app_error('NOT_FOUND', 'User not found.');
  end if;
  if v_status <> 'ACTIVE' then
    perform public.raise_app_error('USER_DISABLED', 'This user is disabled.');
  end if;

  if exists (select 1 from public.group_members
             where group_id = p_group_id and user_id = p_user_id) then
    perform public.raise_app_error('ALREADY_MEMBER', 'This user is already in the group.');
  end if;

  select count(*) into v_active from public.group_members
  where group_id = p_group_id and status = 'ACTIVE';
  if v_active >= 10 then
    perform public.raise_app_error(
      'GROUP_MEMBER_LIMIT', 'A group can have at most 10 active members.');
  end if;

  insert into public.group_members (group_id, user_id, group_role)
  values (p_group_id, p_user_id, coalesce(p_group_role, 'MEMBER'))
  returning * into v_row;
  return v_row;
end;
$$;

create function public.remove_group_member(p_group_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.require_super_admin();
  delete from public.group_members
  where group_id = p_group_id and user_id = p_user_id;
  if not found then
    perform public.raise_app_error('NOT_FOUND', 'Membership not found.');
  end if;
end;
$$;

create function public.set_group_member_status(
  p_group_id uuid,
  p_user_id uuid,
  p_status public.record_status
)
returns public.group_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := public.require_active_user();
  v_member public.group_members;
begin
  select * into v_member from public.group_members
  where group_id = p_group_id and user_id = p_user_id
  for update;
  if v_member.id is null then
    perform public.raise_app_error('NOT_FOUND', 'Membership not found.');
  end if;

  if not public.is_super_admin() then
    if not public.is_group_admin(p_group_id) then
      perform public.raise_app_error('FORBIDDEN', 'You cannot manage this group''s members.');
    end if;
    if p_user_id = v_uid then
      perform public.raise_app_error('FORBIDDEN', 'You cannot change your own status.');
    end if;
    if v_member.group_role = 'GROUP_ADMIN' then
      perform public.raise_app_error('FORBIDDEN', 'You cannot change another Group Admin''s status.');
    end if;
  end if;

  -- Enabling re-checks the 10-member limit (group_members_enforce_limit trigger).
  update public.group_members set status = p_status
  where id = v_member.id
  returning * into v_member;
  return v_member;
end;
$$;

create function public.set_group_member_role(
  p_group_id uuid,
  p_user_id uuid,
  p_group_role public.group_role
)
returns public.group_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.group_members;
begin
  perform public.require_super_admin();
  update public.group_members set group_role = p_group_role
  where group_id = p_group_id and user_id = p_user_id
  returning * into v_row;
  if v_row.id is null then
    perform public.raise_app_error('NOT_FOUND', 'Membership not found.');
  end if;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- Users (profile-only changes; Auth changes are in the admin-users Edge Function)
-- ---------------------------------------------------------------------------
create function public.update_user_name(p_user_id uuid, p_name text)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.profiles;
begin
  perform public.require_super_admin();
  update public.profiles
     set name = public.normalize_name(p_name, 80, 'Name')
   where id = p_user_id
  returning * into v_row;
  if v_row.id is null then
    perform public.raise_app_error('NOT_FOUND', 'User not found.');
  end if;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
grant execute on function
  public.get_my_context(),
  public.create_group(text),
  public.rename_group(uuid, text),
  public.set_group_status(uuid, public.record_status),
  public.add_group_member(uuid, uuid, public.group_role),
  public.remove_group_member(uuid, uuid),
  public.set_group_member_status(uuid, uuid, public.record_status),
  public.set_group_member_role(uuid, uuid, public.group_role),
  public.update_user_name(uuid, text)
to authenticated;
