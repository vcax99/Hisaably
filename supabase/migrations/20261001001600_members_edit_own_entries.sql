-- Owner decision 16 (2026-10-06): a member may edit or delete the entries
-- THEY added (per transaction_history). Group Admins and the Super Admin can
-- still edit or delete any entry of their groups. Entries with no recorded
-- author ("Not recorded") stay admin-only.

-- Internal: may the caller edit/delete this entry?
create function public.can_edit_transaction(p_transaction_id uuid, p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.can_manage_group(p_group_id)
      or (public.is_group_member(p_group_id)
          and exists (
            select 1 from public.transaction_history h
            where h.transaction_id = p_transaction_id
              and h.action = 'CREATED'
              and h.actor_id = auth.uid()));
$$;

create or replace function public.update_transaction(
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
  if not public.can_edit_transaction(v_row.id, v_row.group_id) then
    perform public.raise_app_error('FORBIDDEN',
      'You can edit only the entries you added. Ask your Group Admin to change this one.');
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

create or replace function public.delete_transaction(p_id uuid, p_expected_version bigint default null)
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
  if not public.can_edit_transaction(v_row.id, v_row.group_id) then
    perform public.raise_app_error('FORBIDDEN',
      'You can delete only the entries you added. Ask your Group Admin to delete this one.');
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

-- Adds can_edit: whether the caller may edit/delete this entry (the UI shows
-- Edit/Delete from it; update/delete check the same rule).
create or replace function public.get_transaction_history(p_transaction_id uuid)
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

  return jsonb_build_object(
    'created', v_created,
    'updated', v_updated,
    'can_edit', public.can_edit_transaction(p_transaction_id, v_group));
end;
$$;

revoke execute on all functions in schema public from public, anon;
revoke execute on function public.can_edit_transaction(uuid, uuid) from authenticated;
grant execute on function
  public.update_transaction(uuid, public.transaction_type, numeric, text, text, date, bigint),
  public.delete_transaction(uuid, bigint),
  public.get_transaction_history(uuid)
to authenticated;
