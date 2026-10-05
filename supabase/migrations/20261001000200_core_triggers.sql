-- Hisaably — Phase 2: integrity triggers
-- 1. Auto-create a profile when an auth user is created.
-- 2. Race-safe 10-active-member limit per group (last line of defence; the
--    Phase 3 RPCs also check it).
-- 3. Seed default categories for every new group.

-- ---------------------------------------------------------------------------
-- 1. Profile on auth user creation
-- Users log in with a username (owner decision C). Supabase Auth needs an
-- email, so each user gets a synthetic address '<username>@users.hisaably.invalid'
-- ('.invalid' is a reserved TLD, so mail can never be delivered). The
-- username comes from user metadata, falling back to the email's local part.
-- The role is ALWAYS 'USER' here; metadata can never grant SUPER_ADMIN.
-- ---------------------------------------------------------------------------
create function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
  v_name     text;
  v_email    text;
begin
  v_username := lower(btrim(coalesce(
    nullif(new.raw_user_meta_data ->> 'username', ''),
    split_part(new.email, '@', 1)
  )));
  v_name := btrim(coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), v_username));
  v_email := case
    when new.email ilike '%@users.hisaably.invalid' then null
    else new.email
  end;

  insert into public.profiles (id, name, username, email, role, status)
  values (new.id, v_name, v_username, v_email, 'USER', 'ACTIVE');

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- 2. Max 10 ACTIVE members per group
-- Locking the parent group row serializes concurrent adds/enables for the same
-- group, so two requests racing for the 10th/11th slot cannot both succeed.
-- ---------------------------------------------------------------------------
create function public.enforce_group_member_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active_count integer;
begin
  if new.status <> 'ACTIVE' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'ACTIVE' and old.group_id = new.group_id then
    return new;
  end if;

  perform 1 from public.groups where id = new.group_id for update;

  select count(*) into v_active_count
  from public.group_members
  where group_id = new.group_id
    and status = 'ACTIVE'
    and id <> new.id;

  if v_active_count >= 10 then
    raise exception 'A group can have at most 10 active members'
      using errcode = 'check_violation', hint = 'GROUP_MEMBER_LIMIT';
  end if;

  return new;
end;
$$;

create trigger group_members_enforce_limit
  before insert or update of status, group_id on public.group_members
  for each row execute function public.enforce_group_member_limit();

-- ---------------------------------------------------------------------------
-- 3. Default categories per group (admins can rename/delete them later)
-- ---------------------------------------------------------------------------
create function public.seed_group_categories()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.group_categories (group_id, type, name, sort_order)
  select new.id, c.type::public.transaction_type, c.name, c.sort_order
  from (values
    ('EXPENSE', 'Food',          10),
    ('EXPENSE', 'Groceries',     20),
    ('EXPENSE', 'Rent',          30),
    ('EXPENSE', 'Utilities',     40),
    ('EXPENSE', 'Travel',        50),
    ('EXPENSE', 'Shopping',      60),
    ('EXPENSE', 'Health',        70),
    ('EXPENSE', 'Entertainment', 80),
    ('INCOME',  'Contribution',  10),
    ('INCOME',  'Salary',        20),
    ('INCOME',  'Refund',        30)
  ) as c (type, name, sort_order);
  return new;
end;
$$;

create trigger groups_seed_categories
  after insert on public.groups
  for each row execute function public.seed_group_categories();

-- ---------------------------------------------------------------------------
-- Trigger functions must not be callable through the Data API.
-- ---------------------------------------------------------------------------
revoke all on function public.handle_new_auth_user() from public, anon, authenticated;
revoke all on function public.enforce_group_member_limit() from public, anon, authenticated;
revoke all on function public.seed_group_categories() from public, anon, authenticated;
revoke all on function public.transactions_before_write() from public, anon, authenticated;
revoke all on function public.set_updated_at() from public, anon, authenticated;
