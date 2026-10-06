-- Owner decision 17 (2026-10-06): deleting an entry removes it from the
-- database (hard delete), replacing the soft delete (`deleted_at`) of
-- decision 1. Its history rows go with it (cascade); notifications keep their
-- text but lose the link (transaction_id → null).
--
-- A minimal tombstone (id, group, type: no amount, description or person) is
-- kept for 90 days so that
--   * a phone re-sending the same entry from its offline queue (e.g. after a
--     lost reply) can't bring a deleted entry back, and
--   * opening an old notification can still say "This expense has been
--     deleted".

create table public.deleted_transactions (
  id          uuid primary key,
  group_id    uuid not null references public.groups (id) on delete cascade,
  type        public.transaction_type not null,
  deleted_at  timestamptz not null default now()
);
create index deleted_transactions_deleted_at_idx on public.deleted_transactions (deleted_at);
-- No client grants: read through get_deleted_transaction() only.
alter table public.deleted_transactions enable row level security;

-- Purge entries that were soft-deleted before this change.
insert into public.deleted_transactions (id, group_id, type, deleted_at)
select id, group_id, type, deleted_at from public.transactions where deleted_at is not null
on conflict (id) do nothing;
delete from public.transactions where deleted_at is not null;
-- Nothing is soft-deleted any more.
alter table public.transactions
  add constraint transactions_no_soft_delete check (deleted_at is null);

create or replace function public.delete_transaction(p_id uuid, p_expected_version bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.transactions;
  v_gone public.deleted_transactions;
begin
  perform public.require_active_user();

  select * into v_row from public.transactions where id = p_id for update;
  if v_row.id is null then
    -- Already deleted (e.g. a retry after a lost reply): nothing to do.
    select * into v_gone from public.deleted_transactions where id = p_id;
    if v_gone.id is not null and public.can_view_group(v_gone.group_id) then
      return jsonb_build_object('id', p_id, 'deleted', true);
    end if;
    perform public.raise_app_error('NOT_FOUND', 'Transaction not found.');
  end if;
  if not public.can_edit_transaction(v_row.id, v_row.group_id) then
    perform public.raise_app_error('FORBIDDEN',
      'You can delete only the entries you added. Ask your Group Admin to delete this one.');
  end if;
  if p_expected_version is not null and p_expected_version <> v_row.sync_version then
    perform public.raise_app_error('CONFLICT', 'This transaction was changed by someone else. Refresh and try again.');
  end if;

  insert into public.deleted_transactions (id, group_id, type)
  values (v_row.id, v_row.group_id, v_row.type)
  on conflict (id) do nothing;
  delete from public.transactions where id = p_id;
  return jsonb_build_object('id', p_id, 'deleted', true);
end;
$$;

-- Same as before, plus: a deleted id can't be re-created by a late retry.
create or replace function public.upsert_transaction(
  p_id uuid,
  p_group_id uuid,
  p_type public.transaction_type,
  p_amount numeric,
  p_category text,
  p_description text,
  p_transaction_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid         uuid := public.require_active_user();
  v_existing    public.transactions;
  v_row         public.transactions;
  v_group_state public.record_status;
  v_category    text;
  v_description text := nullif(btrim(coalesce(p_description, '')), '');
  v_title       text;
  v_body        text;
begin
  if p_id is null or p_group_id is null then
    perform public.raise_app_error('VALIDATION', 'Transaction id and group are required.');
  end if;

  -- Retry of an already-synced transaction: return it, change nothing.
  select * into v_existing from public.transactions where id = p_id;
  if v_existing.id is not null then
    if v_existing.group_id <> p_group_id or not public.can_view_group(v_existing.group_id) then
      perform public.raise_app_error('ID_CONFLICT', 'This transaction id is already in use.');
    end if;
    return jsonb_build_object('created', false, 'transaction', to_jsonb(v_existing));
  end if;

  -- Retry of an entry that was synced and then deleted: keep it deleted.
  if exists (select 1 from public.deleted_transactions where id = p_id) then
    perform public.raise_app_error('DELETED', 'This entry was deleted.');
  end if;

  if not public.can_view_group(p_group_id) then
    perform public.raise_app_error('FORBIDDEN', 'You are not an active member of this group.');
  end if;
  select status into v_group_state from public.groups where id = p_group_id;
  if v_group_state is distinct from 'ACTIVE' then
    perform public.raise_app_error('GROUP_DISABLED', 'This group is disabled.');
  end if;

  perform public.validate_transaction_fields(
    p_type, p_amount, p_category, v_description, p_transaction_date);
  v_category := public.ensure_group_category(p_group_id, p_type, p_category);

  insert into public.transactions
    (id, group_id, type, amount, category, description, transaction_date)
  values
    (p_id, p_group_id, p_type, p_amount, v_category, v_description, p_transaction_date)
  on conflict (id) do nothing
  returning * into v_row;

  if v_row.id is null then
    -- Lost a race with a concurrent retry of the same id: treat as a retry.
    select * into v_row from public.transactions where id = p_id;
    return jsonb_build_object('created', false, 'transaction', to_jsonb(v_row));
  end if;

  -- Notify the other active members (never the actor).
  if p_type = 'EXPENSE' then
    v_title := 'Expense Added';
    v_body := public.format_inr(p_amount) || ' • ' || v_category
           || ' • ' || to_char(p_transaction_date, 'FMDD Mon');
  else
    v_title := 'Income Added';
    v_body := public.format_inr(p_amount)
           || coalesce(' • ' || v_category, '')
           || ' • ' || to_char(p_transaction_date, 'FMDD Mon');
  end if;

  insert into public.notifications (group_id, recipient_id, transaction_id, type, title, body)
  select p_group_id, gm.user_id, v_row.id,
         case when p_type = 'EXPENSE' then 'EXPENSE_ADDED' else 'INCOME_ADDED' end::public.notification_type,
         v_title, v_body
  from public.group_members gm
  join public.profiles p on p.id = gm.user_id
  where gm.group_id = p_group_id
    and gm.status = 'ACTIVE'
    and p.status = 'ACTIVE'
    and gm.user_id <> v_uid;

  return jsonb_build_object('created', true, 'transaction', to_jsonb(v_row));
end;
$$;

-- {type: 'EXPENSE'|'INCOME'} when this entry was deleted and the caller can
-- see its group; null otherwise (never existed, or not visible).
create function public.get_deleted_transaction(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_gone public.deleted_transactions;
begin
  perform public.require_active_user();
  select * into v_gone from public.deleted_transactions where id = p_id;
  if v_gone.id is null or not public.can_view_group(v_gone.group_id) then
    return null;
  end if;
  return jsonb_build_object('type', v_gone.type);
end;
$$;

-- Daily cleanup (pg_cron): old read notifications + 90-day-old tombstones.
create function public.purge_deleted_transactions()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from public.deleted_transactions where deleted_at < now() - interval '90 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'hisaably-notification-cleanup') then
    perform cron.unschedule('hisaably-notification-cleanup');
  end if;
  if exists (select 1 from cron.job where jobname = 'hisaably-daily-cleanup') then
    perform cron.unschedule('hisaably-daily-cleanup');
  end if;
  perform cron.schedule(
    'hisaably-daily-cleanup',
    '30 21 * * *',  -- 03:00 IST
    'select public.purge_read_notifications(); select public.purge_deleted_transactions();'
  );
end
$$;

revoke execute on all functions in schema public from public, anon;
revoke execute on function public.purge_deleted_transactions() from authenticated;
grant execute on function
  public.delete_transaction(uuid, bigint),
  public.upsert_transaction(uuid, uuid, public.transaction_type, numeric, text, text, date),
  public.get_deleted_transaction(uuid)
to authenticated;
