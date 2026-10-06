-- Owner decision 15 (2026-10-06): show who added and who last edited an entry,
-- and let users delete/auto-delete their notifications.
--
-- 1. Entry history lives in its own table, so `transactions` keeps no user
--    reference (the group still owns the money; totals, sync and the offline
--    store are unaffected). Rows are written by a trigger from the caller's
--    auth.uid(); clients read them only through get_transaction_history().
-- 2. notifications.read_at + a per-user retention (Never / 7 / 15 days after
--    reading, default 7). A daily pg_cron job deletes read notifications past
--    their user's retention. delete_all_notifications() clears a user's list.

-- ---------------------------------------------------------------------------
-- 1. Entry history
-- ---------------------------------------------------------------------------
create table public.transaction_history (
  id              uuid primary key default gen_random_uuid(),
  transaction_id  uuid not null references public.transactions (id) on delete cascade,
  action          text not null,
  -- Null once the user is deleted ("Deleted user").
  actor_id        uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  constraint transaction_history_action check (action in ('CREATED', 'UPDATED', 'DELETED'))
);

create index transaction_history_tx_idx
  on public.transaction_history (transaction_id, action, created_at desc);
create index transaction_history_actor_idx
  on public.transaction_history (actor_id);

-- No client grants: read via get_transaction_history() only.
alter table public.transaction_history enable row level security;

create function public.record_transaction_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_action text;
begin
  -- Only requests made by a signed-in user are attributed (not SQL scripts or
  -- jobs), and a category rename rewrites past entries without editing them.
  if v_actor is null
     or coalesce(current_setting('hisaably.category_rename', true), '') = 'on' then
    return null;
  end if;

  if tg_op = 'INSERT' then
    v_action := 'CREATED';
  elsif old.deleted_at is null and new.deleted_at is not null then
    v_action := 'DELETED';
  elsif (new.type, new.amount, new.category, new.description, new.transaction_date)
        is distinct from
        (old.type, old.amount, old.category, old.description, old.transaction_date) then
    v_action := 'UPDATED';
  else
    return null;  -- nothing a person would call an edit
  end if;

  insert into public.transaction_history (transaction_id, action, actor_id)
  values (new.id, v_action, v_actor);
  return null;
end;
$$;

create trigger transactions_record_history
  after insert or update on public.transactions
  for each row execute function public.record_transaction_history();

-- Same as before, plus the flag that keeps the cascade out of the history.
create or replace function public.rename_group_category(p_category_id uuid, p_name text)
returns public.group_categories
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cat public.group_categories;
  v_old text;
  v_new text := public.normalize_name(p_name, 40, 'Category');
begin
  perform public.require_active_user();
  select * into v_cat from public.group_categories where id = p_category_id for update;
  if v_cat.id is null then
    perform public.raise_app_error('NOT_FOUND', 'Category not found.');
  end if;
  if not public.can_manage_group(v_cat.group_id) then
    perform public.raise_app_error('FORBIDDEN', 'Only the Group Admin can edit categories.');
  end if;
  if exists (select 1 from public.group_categories
             where group_id = v_cat.group_id and type = v_cat.type and id <> v_cat.id
               and lower(btrim(name)) = lower(v_new)) then
    perform public.raise_app_error('CATEGORY_EXISTS', 'A category with this name already exists.');
  end if;

  v_old := v_cat.name;
  update public.group_categories set name = v_new where id = v_cat.id
  returning * into v_cat;

  -- Decision 8: renaming also renames it on past transactions of this group.
  -- That's not an edit of those entries, so it stays out of their history.
  perform set_config('hisaably.category_rename', 'on', true);
  update public.transactions
     set category = v_new
   where group_id = v_cat.group_id
     and type = v_cat.type
     and lower(btrim(category)) = lower(btrim(v_old));
  perform set_config('hisaably.category_rename', 'off', true);

  return v_cat;
end;
$$;

-- {created: {name, at} | null, updated: {name, at} | null}
-- name is null when that user has since been deleted. "created" is null for
-- entries added before history was recorded.
create function public.get_transaction_history(p_transaction_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_created jsonb;
  v_updated jsonb;
begin
  perform public.require_active_user();
  select group_id into v_group from public.transactions where id = p_transaction_id;
  if v_group is null or not public.can_view_group(v_group) then
    perform public.raise_app_error('NOT_FOUND', 'Transaction not found.');
  end if;

  select jsonb_build_object('name', p.name, 'at', h.created_at) into v_created
  from public.transaction_history h
  left join public.profiles p on p.id = h.actor_id
  where h.transaction_id = p_transaction_id and h.action = 'CREATED'
  order by h.created_at
  limit 1;

  select jsonb_build_object('name', p.name, 'at', h.created_at) into v_updated
  from public.transaction_history h
  left join public.profiles p on p.id = h.actor_id
  where h.transaction_id = p_transaction_id and h.action = 'UPDATED'
  order by h.created_at desc
  limit 1;

  return jsonb_build_object('created', v_created, 'updated', v_updated);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Notification read time, retention and cleanup
-- ---------------------------------------------------------------------------
alter table public.notifications add column read_at timestamptz;
-- Already-read notifications count as read now (first cleanup in 7 days).
update public.notifications set read_at = now() where is_read and read_at is null;

create function public.notifications_set_read_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_read and not old.is_read then
    new.read_at := now();
  elsif not new.is_read then
    new.read_at := null;
  end if;
  return new;
end;
$$;

create trigger notifications_read_at
  before update of is_read on public.notifications
  for each row execute function public.notifications_set_read_at();

create index notifications_read_cleanup_idx
  on public.notifications (recipient_id, read_at) where is_read;

-- Days after reading before a notification is deleted; null = never.
alter table public.profiles
  add column notification_retention_days smallint default 7,
  add constraint profiles_notification_retention
    check (notification_retention_days is null or notification_retention_days in (7, 15));

create function public.get_notification_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_active_user();
begin
  return jsonb_build_object(
    'retention_days',
    (select notification_retention_days from public.profiles where id = v_uid));
end;
$$;

-- p_days: 7, 15, or null for "never".
create function public.set_notification_retention(p_days integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_active_user();
begin
  if p_days is not null and p_days not in (7, 15) then
    perform public.raise_app_error('VALIDATION', 'Choose Never, 7 days or 15 days.');
  end if;
  update public.profiles set notification_retention_days = p_days where id = v_uid;
  return jsonb_build_object('retention_days', p_days);
end;
$$;

create function public.delete_all_notifications()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_active_user();
  v_count integer;
begin
  delete from public.notifications where recipient_id = v_uid;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Internal (pg_cron): deletes read notifications past each user's retention.
create function public.purge_read_notifications()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from public.notifications n
   using public.profiles p
   where p.id = n.recipient_id
     and p.notification_retention_days is not null
     and n.is_read
     and n.read_at < now() - make_interval(days => p.notification_retention_days);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Daily at 03:00 IST (= 21:30 UTC).
do $$
begin
  if exists (select 1 from cron.job where jobname = 'hisaably-notification-cleanup') then
    perform cron.unschedule('hisaably-notification-cleanup');
  end if;
  perform cron.schedule(
    'hisaably-notification-cleanup',
    '30 21 * * *',
    'select public.purge_read_notifications()'
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
revoke execute on function
  public.record_transaction_history(),
  public.notifications_set_read_at(),
  public.purge_read_notifications()
from authenticated;
grant execute on function
  public.rename_group_category(uuid, text),
  public.get_transaction_history(uuid),
  public.get_notification_settings(),
  public.set_notification_retention(integer),
  public.delete_all_notifications()
to authenticated;
