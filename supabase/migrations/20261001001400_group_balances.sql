-- Dashboard "By group" breakdown: one row per group the caller can see
-- (Super Admin: all groups; others: their active groups), with the live
-- balance and the selected month's income/expense. One round trip,
-- aggregated on the server (spec: no client-side totals).
create function public.get_group_balances(p_month date default null)
returns table (
  group_id         uuid,
  name             text,
  status           public.record_status,
  current_balance  numeric,
  month_income     numeric,
  month_expense    numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_groups uuid[] := public.resolve_visible_groups(null);
  v_month  date := date_trunc('month', coalesce(p_month, public.ist_today()))::date;
  v_next   date := (v_month + interval '1 month')::date;
begin
  return query
  select g.id, g.name, g.status,
         coalesce(sum(case when t.type = 'INCOME' then t.amount else -t.amount end), 0),
         coalesce(sum(t.amount) filter (where t.type = 'INCOME'
                                          and t.transaction_date >= v_month
                                          and t.transaction_date < v_next), 0),
         coalesce(sum(t.amount) filter (where t.type = 'EXPENSE'
                                          and t.transaction_date >= v_month
                                          and t.transaction_date < v_next), 0)
  from public.groups g
  left join public.transactions t
         on t.group_id = g.id and t.deleted_at is null
  where g.id = any (v_groups)
  group by g.id, g.name, g.status
  order by lower(g.name);
end;
$$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.get_group_balances(date) to authenticated;
