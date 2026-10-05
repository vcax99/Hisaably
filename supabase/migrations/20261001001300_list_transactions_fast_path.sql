-- Phase 13: list_transactions builds its query from the filters actually
-- given (bound parameters only — no user text is ever concatenated), so:
--   * a single group uses `group_id = $1[1]` → ordered index range scan on
--     transactions_group_keyset_idx + LIMIT (0.06 ms vs 6 ms at 20k rows,
--     and constant as history grows);
--   * the keyset cursor becomes an index condition instead of a filter;
--   * several groups (Super Admin "All groups", "All my groups") keep ANY.
-- Same signature, same semantics, grants unchanged.
create or replace function public.list_transactions(
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
  v_sql    text;
begin
  v_sql := 'select t.* from public.transactions t where t.deleted_at is null and '
        || case when cardinality(v_groups) = 1
                then 't.group_id = ($1)[1]'
                else 't.group_id = any ($1)' end;
  if p_type is not null then v_sql := v_sql || ' and t.type = $2'; end if;
  if p_from is not null then v_sql := v_sql || ' and t.transaction_date >= $3'; end if;
  if p_to is not null then v_sql := v_sql || ' and t.transaction_date <= $4'; end if;
  if p_category is not null then
    v_sql := v_sql || ' and lower(t.category) = lower(btrim($5))';
  end if;
  if p_min_amount is not null then v_sql := v_sql || ' and t.amount >= $6'; end if;
  if p_max_amount is not null then v_sql := v_sql || ' and t.amount <= $7'; end if;
  if p_cursor_date is not null then
    v_sql := v_sql || ' and (t.transaction_date, t.created_at, t.id) < ($8, $9, $10)';
  end if;
  v_sql := v_sql
        || ' order by t.transaction_date desc, t.created_at desc, t.id desc limit $11';

  return query execute v_sql
    using v_groups, p_type, p_from, p_to, p_category, p_min_amount, p_max_amount,
          p_cursor_date, p_cursor_created_at, p_cursor_id,
          least(greatest(coalesce(p_limit, 30), 1), 100);
end;
$$;

revoke execute on all functions in schema public from public, anon;
