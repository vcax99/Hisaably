-- Hisaably — Phase 3: transaction and category RPCs
--
--   upsert_transaction      any active member of the (active) group, or SUPER_ADMIN.
--                           IDEMPOTENT on the client-generated id: a retry returns
--                           the existing row with created = false and sends no
--                           second notification.
--   update_transaction      that group's GROUP_ADMIN or SUPER_ADMIN (decision 1),
--   delete_transaction      with optional optimistic concurrency (expected version).
--   list_transactions       keyset-paginated, newest first.
--   rename/delete category  that group's GROUP_ADMIN or SUPER_ADMIN (decision 8).
--
-- The actor's id (auth.uid()) is used only to exclude them from notifications;
-- it is never stored on the transaction.

-- ---------------------------------------------------------------------------
-- Formatting for notification text: Indian digit grouping, e.g. ₹1,23,456.50
-- ---------------------------------------------------------------------------
create function public.format_inr(p_amount numeric)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_abs  numeric := abs(round(p_amount, 2));
  v_int  text := trunc(v_abs)::text;
  v_frac integer := ((v_abs - trunc(v_abs)) * 100)::integer;
  v_out  text;
begin
  if char_length(v_int) > 3 then
    v_out := right(v_int, 3);
    v_int := left(v_int, char_length(v_int) - 3);
    while char_length(v_int) > 2 loop
      v_out := right(v_int, 2) || ',' || v_out;
      v_int := left(v_int, char_length(v_int) - 2);
    end loop;
    v_out := v_int || ',' || v_out;
  else
    v_out := v_int;
  end if;

  return case when p_amount < 0 then '-' else '' end
      || '₹' || v_out
      || case when v_frac > 0 then '.' || lpad(v_frac::text, 2, '0') else '' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Returns the canonical category name for a group, creating it when it's new
-- (the "Other" flow; also works for offline-created transactions at sync time).
-- Existing names match case-insensitively ("food" -> "Food"). A deleted
-- (inactive) category is NOT re-activated: the transaction keeps the text.
create function public.ensure_group_category(
  p_group_id uuid,
  p_type public.transaction_type,
  p_name text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name     text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_existing text;
begin
  if v_name = '' then
    return null;
  end if;
  if char_length(v_name) > 40 then
    perform public.raise_app_error('VALIDATION', 'Category must be at most 40 characters.');
  end if;

  select name into v_existing
  from public.group_categories
  where group_id = p_group_id and type = p_type
    and lower(btrim(name)) = lower(v_name);
  if v_existing is not null then
    return v_existing;
  end if;

  insert into public.group_categories (group_id, type, name)
  values (p_group_id, p_type, v_name)
  on conflict do nothing;
  return v_name;
end;
$$;

create function public.validate_transaction_fields(
  p_type public.transaction_type,
  p_amount numeric,
  p_category text,
  p_description text,
  p_transaction_date date
)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_type is null then
    perform public.raise_app_error('VALIDATION', 'Choose income or expense.');
  end if;
  if p_amount is null or p_amount <= 0 then
    perform public.raise_app_error('VALIDATION', 'Amount must be greater than zero.');
  end if;
  if p_amount <> round(p_amount, 2) then
    perform public.raise_app_error('VALIDATION', 'Amount can have at most 2 decimal places.');
  end if;
  if p_amount >= 1000000000000 then
    perform public.raise_app_error('VALIDATION', 'Amount is too large.');
  end if;
  if p_transaction_date is null then
    perform public.raise_app_error('VALIDATION', 'Choose a date.');
  end if;
  if p_transaction_date > public.ist_today() then
    perform public.raise_app_error('FUTURE_DATE', 'Transaction date cannot be in the future.');
  end if;
  if p_transaction_date < date '2000-01-01' then
    perform public.raise_app_error('VALIDATION', 'Date is too far in the past.');
  end if;
  if p_type = 'EXPENSE' and btrim(coalesce(p_category, '')) = '' then
    perform public.raise_app_error('VALIDATION', 'Choose a category for the expense.');
  end if;
  if char_length(coalesce(p_description, '')) > 500 then
    perform public.raise_app_error('VALIDATION', 'Description must be at most 500 characters.');
  end if;
end;
$$;

-- Resolves "which groups" for list/dashboard calls: one group (permission-checked)
-- or, when null, every group the caller can see.
create function public.resolve_visible_groups(p_group_id uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  perform public.require_active_user();
  if p_group_id is not null then
    if not public.can_view_group(p_group_id) then
      perform public.raise_app_error('FORBIDDEN', 'You do not have access to this group.');
    end if;
    return array[p_group_id];
  end if;

  if public.is_super_admin() then
    select coalesce(array_agg(id), '{}') into v_ids from public.groups;
  else
    select coalesce(array_agg(gm.group_id), '{}') into v_ids
    from public.group_members gm
    join public.groups g on g.id = gm.group_id
    where gm.user_id = auth.uid() and gm.status = 'ACTIVE' and g.status = 'ACTIVE';
  end if;
  return v_ids;
end;
$$;

-- ---------------------------------------------------------------------------
-- Create (idempotent)
-- ---------------------------------------------------------------------------
create function public.upsert_transaction(
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

  -- Notify the other active members (never the actor). Push delivery is
  -- attached in Phase 11; these rows are the notification history.
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

-- ---------------------------------------------------------------------------
-- Edit / delete (Group Admin of the group or Super Admin)
-- ---------------------------------------------------------------------------
create function public.update_transaction(
  p_id uuid,
  p_type public.transaction_type,
  p_amount numeric,
  p_category text,
  p_description text,
  p_transaction_date date,
  p_expected_version bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row         public.transactions;
  v_description text := nullif(btrim(coalesce(p_description, '')), '');
  v_category    text;
begin
  perform public.require_active_user();

  select * into v_row from public.transactions where id = p_id for update;
  if v_row.id is null or v_row.deleted_at is not null then
    perform public.raise_app_error('NOT_FOUND', 'Transaction not found.');
  end if;
  if not public.can_manage_group(v_row.group_id) then
    perform public.raise_app_error('FORBIDDEN', 'Only the Group Admin can edit transactions.');
  end if;
  if p_expected_version is not null and p_expected_version <> v_row.sync_version then
    perform public.raise_app_error('CONFLICT', 'This transaction was changed by someone else. Refresh and try again.');
  end if;

  perform public.validate_transaction_fields(
    p_type, p_amount, p_category, v_description, p_transaction_date);
  v_category := public.ensure_group_category(v_row.group_id, p_type, p_category);

  update public.transactions
     set type = p_type,
         amount = p_amount,
         category = v_category,
         description = v_description,
         transaction_date = p_transaction_date
   where id = p_id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

create function public.delete_transaction(p_id uuid, p_expected_version bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.transactions;
begin
  perform public.require_active_user();

  select * into v_row from public.transactions where id = p_id for update;
  if v_row.id is null then
    perform public.raise_app_error('NOT_FOUND', 'Transaction not found.');
  end if;
  if not public.can_manage_group(v_row.group_id) then
    perform public.raise_app_error('FORBIDDEN', 'Only the Group Admin can delete transactions.');
  end if;
  if v_row.deleted_at is not null then
    return to_jsonb(v_row);  -- already deleted: idempotent
  end if;
  if p_expected_version is not null and p_expected_version <> v_row.sync_version then
    perform public.raise_app_error('CONFLICT', 'This transaction was changed by someone else. Refresh and try again.');
  end if;

  update public.transactions set deleted_at = now() where id = p_id
  returning * into v_row;
  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------------
-- List (keyset pagination: pass the last row's date/created_at/id as cursor)
-- ---------------------------------------------------------------------------
create function public.list_transactions(
  p_group_id uuid default null,
  p_type public.transaction_type default null,
  p_from date default null,
  p_to date default null,
  p_category text default null,
  p_min_amount numeric default null,
  p_max_amount numeric default null,
  p_cursor_date date default null,
  p_cursor_created_at timestamptz default null,
  p_cursor_id uuid default null,
  p_limit integer default 30
)
returns setof public.transactions
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_groups uuid[] := public.resolve_visible_groups(p_group_id);
begin
  return query
  select t.*
  from public.transactions t
  where t.group_id = any (v_groups)
    and t.deleted_at is null
    and (p_type is null or t.type = p_type)
    and (p_from is null or t.transaction_date >= p_from)
    and (p_to is null or t.transaction_date <= p_to)
    and (p_category is null or lower(t.category) = lower(btrim(p_category)))
    and (p_min_amount is null or t.amount >= p_min_amount)
    and (p_max_amount is null or t.amount <= p_max_amount)
    and (
      p_cursor_date is null
      or (t.transaction_date, t.created_at, t.id)
         < (p_cursor_date, p_cursor_created_at, p_cursor_id)
    )
  order by t.transaction_date desc, t.created_at desc, t.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;

-- ---------------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------------
create function public.rename_group_category(p_category_id uuid, p_name text)
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
  update public.transactions
     set category = v_new
   where group_id = v_cat.group_id
     and type = v_cat.type
     and lower(btrim(category)) = lower(btrim(v_old));

  return v_cat;
end;
$$;

create function public.delete_group_category(p_category_id uuid)
returns public.group_categories
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cat public.group_categories;
begin
  perform public.require_active_user();
  select * into v_cat from public.group_categories where id = p_category_id;
  if v_cat.id is null then
    perform public.raise_app_error('NOT_FOUND', 'Category not found.');
  end if;
  if not public.can_manage_group(v_cat.group_id) then
    perform public.raise_app_error('FORBIDDEN', 'Only the Group Admin can delete categories.');
  end if;
  -- Decision 8: hidden for new entries; past transactions keep their text.
  update public.group_categories set is_active = false where id = v_cat.id
  returning * into v_cat;
  return v_cat;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
grant execute on function
  public.upsert_transaction(uuid, uuid, public.transaction_type, numeric, text, text, date),
  public.update_transaction(uuid, public.transaction_type, numeric, text, text, date, bigint),
  public.delete_transaction(uuid, bigint),
  public.list_transactions(uuid, public.transaction_type, date, date, text, numeric, numeric, date, timestamptz, uuid, integer),
  public.rename_group_category(uuid, text),
  public.delete_group_category(uuid)
to authenticated;
