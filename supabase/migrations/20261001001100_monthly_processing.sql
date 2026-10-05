-- Phase 12: monthly processing (spec §25).
-- On the 1st of each month (00:05 Asia/Kolkata) for every ACTIVE group:
--   1. refresh the previous month's monthly_summaries row (a derived cache;
--      balances RPCs stay authoritative),
--   2. notify every ACTIVE member of the group (active profile) once:
--      "New Month Started" with last month's closing = this month's opening.
-- Idempotent: summaries are upserted; notifications carry a dedupe_key
-- (MONTH_STARTED:<group>:<yyyy-mm>:<recipient>). No carry-forward rows are
-- ever written to transactions.

create extension if not exists pg_cron;

create function public.run_monthly_processing(p_month date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today          date := public.ist_today();
  v_month          date := date_trunc('month', coalesce(p_month, v_today))::date;
  v_prev           date := (v_month - interval '1 month')::date;
  v_summaries      integer;
  v_notifications  integer;
begin
  -- The cron runs daily (pg_cron has no "1st at IST midnight" for UTC
  -- servers); without an explicit month it only acts on the 1st.
  if p_month is null and extract(day from v_today) <> 1 then
    return jsonb_build_object('skipped', 'not the first of the month');
  end if;

  -- 1. Summaries for the month that just ended.
  with active_groups as (
    select g.id from public.groups g where g.status = 'ACTIVE'
  ),
  bal as (
    select ag.id as group_id,
           coalesce(sum(case when t.type = 'INCOME' then t.amount else -t.amount end)
                    filter (where t.transaction_date < v_prev), 0)               as opening,
           coalesce(sum(t.amount)
                    filter (where t.type = 'INCOME' and t.transaction_date >= v_prev), 0)  as income,
           coalesce(sum(t.amount)
                    filter (where t.type = 'EXPENSE' and t.transaction_date >= v_prev), 0) as expense
    from active_groups ag
    left join public.transactions t
           on t.group_id = ag.id
          and t.deleted_at is null
          and t.transaction_date < v_month
    group by ag.id
  )
  insert into public.monthly_summaries
    (group_id, year, month, opening_balance, total_income, total_expense, closing_balance)
  select b.group_id, extract(year from v_prev)::int, extract(month from v_prev)::int,
         b.opening, b.income, b.expense, b.opening + b.income - b.expense
  from bal b
  on conflict (group_id, year, month) do update
    set opening_balance = excluded.opening_balance,
        total_income    = excluded.total_income,
        total_expense   = excluded.total_expense,
        closing_balance = excluded.closing_balance,
        updated_at      = now();
  get diagnostics v_summaries = row_count;

  -- 2. One notification per active member per group, once (one statement,
  --    so push dispatch batches it).
  insert into public.notifications
    (group_id, recipient_id, type, title, body, dedupe_key)
  select g.id, gm.user_id, 'MONTH_STARTED',
         'New Month Started — ' || to_char(v_month, 'FMMonth YYYY'),
         g.name || ' • Closing (' || to_char(v_prev, 'FMMon') || ') '
           || public.format_inr(ms.closing_balance)
           || ' • Opening (' || to_char(v_month, 'FMMon') || ') '
           || public.format_inr(ms.closing_balance),
         'MONTH_STARTED:' || g.id || ':' || to_char(v_month, 'YYYY-MM') || ':' || gm.user_id
  from public.groups g
  join public.monthly_summaries ms
    on ms.group_id = g.id
   and ms.year = extract(year from v_prev)::int
   and ms.month = extract(month from v_prev)::int
  join public.group_members gm on gm.group_id = g.id and gm.status = 'ACTIVE'
  join public.profiles p on p.id = gm.user_id and p.status = 'ACTIVE'
  where g.status = 'ACTIVE'
  on conflict (dedupe_key) do nothing;
  get diagnostics v_notifications = row_count;

  return jsonb_build_object(
    'month', v_month,
    'summaries', v_summaries,
    'notifications', v_notifications
  );
end;
$$;

-- Daily at 00:05 IST (= 18:35 UTC); acts only on the 1st (see above).
do $$
begin
  if exists (select 1 from cron.job where jobname = 'hisaably-monthly') then
    perform cron.unschedule('hisaably-monthly');
  end if;
  perform cron.schedule(
    'hisaably-monthly',
    '35 18 * * *',
    'select public.run_monthly_processing()'
  );
end
$$;

-- Internal job function: never callable by clients.
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.run_monthly_processing(date) from authenticated;
