-- Hisaably — Phase 3: reporting and notification RPCs
--
-- Balances are ALWAYS computed from `transactions` (the source of truth), so
-- backdated entries, edits and deletes are reflected immediately:
--   closing(month) = opening(month) + income(month) - expense(month)
--   opening(month) = closing(previous month) = net of everything before it
-- `monthly_summaries` stays a cache for the monthly job (Phase 12) and is
-- never read here. All aggregation runs server-side; the app downloads totals,
-- not raw transactions.

-- ---------------------------------------------------------------------------
-- Month-by-month balances for one group, or (null) all visible groups combined.
-- ---------------------------------------------------------------------------
create function public.get_monthly_balances(
  p_group_id uuid,
  p_from_month date,
  p_to_month date
)
returns table (
  month_start      date,
  opening_balance  numeric,
  total_income     numeric,
  total_expense    numeric,
  closing_balance  numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_groups uuid[] := public.resolve_visible_groups(p_group_id);
  v_from   date := date_trunc('month', p_from_month)::date;
  v_to     date := date_trunc('month', p_to_month)::date;
begin
  if v_from is null or v_to is null or v_to < v_from then
    perform public.raise_app_error('VALIDATION', 'Invalid month range.');
  end if;
  if v_to > (v_from + interval '120 months')::date then
    perform public.raise_app_error('VALIDATION', 'Month range is too long.');
  end if;

  return query
  with opening as (
    select coalesce(sum(case when t.type = 'INCOME' then t.amount else -t.amount end), 0) as amount
    from public.transactions t
    where t.group_id = any (v_groups)
      and t.deleted_at is null
      and t.transaction_date < v_from
  ),
  months as (
    select gs::date as m
    from generate_series(v_from, v_to, interval '1 month') as gs
  ),
  agg as (
    select date_trunc('month', t.transaction_date)::date as m,
           coalesce(sum(t.amount) filter (where t.type = 'INCOME'), 0)  as inc,
           coalesce(sum(t.amount) filter (where t.type = 'EXPENSE'), 0) as exp
    from public.transactions t
    where t.group_id = any (v_groups)
      and t.deleted_at is null
      and t.transaction_date >= v_from
      and t.transaction_date < (v_to + interval '1 month')::date
    group by 1
  ),
  rolled as (
    select mo.m,
           coalesce(a.inc, 0) as inc,
           coalesce(a.exp, 0) as exp,
           o.amount + sum(coalesce(a.inc, 0) - coalesce(a.exp, 0))
             over (order by mo.m rows between unbounded preceding and current row) as closing
    from months mo
    cross join opening o
    left join agg a on a.m = mo.m
  )
  select r.m, r.closing - r.inc + r.exp, r.inc, r.exp, r.closing
  from rolled r
  order by r.m;
end;
$$;

-- ---------------------------------------------------------------------------
-- Category totals for a date range (expense breakdown / income summary).
-- ---------------------------------------------------------------------------
create function public.get_category_breakdown(
  p_group_id uuid,
  p_type public.transaction_type,
  p_from date,
  p_to date
)
returns table (category text, total numeric, transaction_count bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_groups uuid[] := public.resolve_visible_groups(p_group_id);
begin
  return query
  select coalesce(t.category, 'Uncategorised'), sum(t.amount), count(*)
  from public.transactions t
  where t.group_id = any (v_groups)
    and t.deleted_at is null
    and t.type = p_type
    and t.transaction_date between p_from and p_to
  group by 1
  order by 2 desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- One round trip for a dashboard screen: selected month's summary, balance
-- today, 6-month trend, expense breakdown and recent transactions.
-- ---------------------------------------------------------------------------
create function public.get_dashboard(
  p_group_id uuid default null,
  p_month date default null,
  p_recent_limit integer default 5
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_groups  uuid[] := public.resolve_visible_groups(p_group_id);
  v_month   date := date_trunc('month', coalesce(p_month, public.ist_today()))::date;
  v_month_end date := (v_month + interval '1 month - 1 day')::date;
  v_summary jsonb;
  v_trend   jsonb;
  v_balance numeric;
begin
  select coalesce(sum(case when type = 'INCOME' then amount else -amount end), 0)
    into v_balance
  from public.transactions
  where group_id = any (v_groups) and deleted_at is null;

  select jsonb_agg(jsonb_build_object(
           'month', b.month_start,
           'opening_balance', b.opening_balance,
           'total_income', b.total_income,
           'total_expense', b.total_expense,
           'closing_balance', b.closing_balance) order by b.month_start)
    into v_trend
  from public.get_monthly_balances(p_group_id, (v_month - interval '5 months')::date, v_month) b;

  v_summary := v_trend -> -1;

  return jsonb_build_object(
    'group_ids', to_jsonb(v_groups),
    'month', v_month,
    'current_balance', v_balance,
    'month_summary', v_summary,
    'trend', coalesce(v_trend, '[]'::jsonb),
    'expense_breakdown', coalesce((
      select jsonb_agg(jsonb_build_object(
               'category', c.category, 'total', c.total, 'count', c.transaction_count))
      from public.get_category_breakdown(p_group_id, 'EXPENSE', v_month, v_month_end) c
    ), '[]'::jsonb),
    'recent_transactions', coalesce((
      select jsonb_agg(to_jsonb(r))
      from (
        select t.*
        from public.transactions t
        where t.group_id = any (v_groups) and t.deleted_at is null
        order by t.transaction_date desc, t.created_at desc, t.id desc
        limit least(greatest(coalesce(p_recent_limit, 5), 0), 20)
      ) r
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Super Admin overview counts (financial totals come from get_dashboard(null)).
-- ---------------------------------------------------------------------------
create function public.get_admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_super_admin();
  return jsonb_build_object(
    'users_total',    (select count(*) from public.profiles),
    'users_active',   (select count(*) from public.profiles where status = 'ACTIVE'),
    'users_disabled', (select count(*) from public.profiles where status = 'DISABLED'),
    'groups_total',   (select count(*) from public.groups),
    'groups_active',  (select count(*) from public.groups where status = 'ACTIVE')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------
create function public.register_device(p_token text, p_platform public.device_platform)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_active_user();
begin
  if p_token is null or btrim(p_token) = '' or char_length(p_token) > 4096 then
    perform public.raise_app_error('VALIDATION', 'Invalid device token.');
  end if;
  -- A physical device belongs to whoever is signed in on it now.
  update public.notification_devices
     set is_active = false
   where device_token = p_token and user_id <> v_uid and is_active;

  insert into public.notification_devices (user_id, device_token, platform, is_active)
  values (v_uid, p_token, p_platform, true)
  on conflict (user_id, device_token)
  do update set is_active = true, platform = excluded.platform;
end;
$$;

create function public.unregister_device(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    perform public.raise_app_error('NOT_AUTHENTICATED', 'Please sign in again.');
  end if;
  -- Allowed for disabled users too (logout must always succeed).
  update public.notification_devices
     set is_active = false
   where user_id = auth.uid() and device_token = p_token;
end;
$$;

create function public.mark_notification_read(p_notification_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_active_user();
begin
  update public.notifications
     set is_read = true
   where id = p_notification_id and recipient_id = v_uid;
end;
$$;

create function public.mark_all_notifications_read()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := public.require_active_user();
  v_count integer;
begin
  update public.notifications set is_read = true
   where recipient_id = v_uid and not is_read;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
grant execute on function
  public.get_monthly_balances(uuid, date, date),
  public.get_category_breakdown(uuid, public.transaction_type, date, date),
  public.get_dashboard(uuid, date, integer),
  public.get_admin_overview(),
  public.register_device(text, public.device_platform),
  public.unregister_device(text),
  public.mark_notification_read(uuid),
  public.mark_all_notifications_read()
to authenticated;
