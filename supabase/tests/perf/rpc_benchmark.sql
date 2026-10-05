-- RPC performance benchmark (Phase 13). Seeds a group with 20,000
-- transactions over 24 months, times the hot RPCs as a member, captures the
-- list query plan, then rolls everything back (ends with an exception).
--
--   npx supabase db query --linked -f supabase/tests/perf/rpc_benchmark.sql

do $$
declare
  u uuid := gen_random_uuid();
  g uuid;
  t0 timestamptz;
  v_report text := '';
  v_plan text;
  v_json jsonb;
  r record;
  c_date date; c_created timestamptz; c_id uuid;
  i int;
  v_today date := public.ist_today();
  v_month date := date_trunc('month', public.ist_today())::date;
begin
  insert into auth.users (id, email, raw_user_meta_data)
  values (u, 'perf@users.hisaably.invalid', '{"username":"perf_user"}');
  insert into public.groups (name) values ('Perf Group') returning id into g;
  insert into public.group_members (group_id, user_id, group_role) values (g, u, 'GROUP_ADMIN');

  insert into public.transactions (id, group_id, type, amount, category, transaction_date, created_at)
  select gen_random_uuid(), g,
         (case when n % 5 = 0 then 'INCOME' else 'EXPENSE' end)::public.transaction_type,
         (100 + (n * 37) % 5000)::numeric,
         'Cat ' || (n % 50),
         public.ist_today() - (n % 730),
         now() - (n || ' seconds')::interval
  from generate_series(1, 20000) n;
  analyze public.transactions;

  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- First page, then 20 pages deep via keyset.
  t0 := clock_timestamp();
  select count(*) into i from public.list_transactions(p_group_id => g, p_limit => 31);
  v_report := v_report || format('list p1: %s ms; ', round(extract(epoch from clock_timestamp() - t0) * 1000, 1));

  for i in 1..20 loop
    select t.transaction_date, t.created_at, t.id into c_date, c_created, c_id
    from public.list_transactions(p_group_id => g, p_limit => 30,
           p_cursor_date => c_date, p_cursor_created_at => c_created, p_cursor_id => c_id) t
    order by t.transaction_date, t.created_at, t.id limit 1;
  end loop;
  t0 := clock_timestamp();
  perform * from public.list_transactions(p_group_id => g, p_limit => 31,
           p_cursor_date => c_date, p_cursor_created_at => c_created, p_cursor_id => c_id);
  v_report := v_report || format('list p21: %s ms; ', round(extract(epoch from clock_timestamp() - t0) * 1000, 1));

  t0 := clock_timestamp();
  select count(*) into i from public.list_transactions(p_group_id => g, p_type => 'EXPENSE',
           p_from => v_month, p_to => v_today, p_limit => 31);
  v_report := v_report || format('list month+type: %s ms; ', round(extract(epoch from clock_timestamp() - t0) * 1000, 1));

  t0 := clock_timestamp();
  v_json := public.get_dashboard(g, v_month, 5);
  v_report := v_report || format('dashboard: %s ms; ', round(extract(epoch from clock_timestamp() - t0) * 1000, 1));

  t0 := clock_timestamp();
  perform * from public.get_monthly_balances(g, v_today - 730, v_today);
  v_report := v_report || format('balances 24m: %s ms; ', round(extract(epoch from clock_timestamp() - t0) * 1000, 1));

  t0 := clock_timestamp();
  perform * from public.get_category_breakdown(g, 'EXPENSE', v_month, v_today);
  v_report := v_report || format('breakdown: %s ms; ', round(extract(epoch from clock_timestamp() - t0) * 1000, 1));

  perform set_config('role', 'none', true);

  -- Plan of the list query's core (first page).
  for r in execute format($q$
    explain (analyze, costs off, timing off, summary on)
    select t.* from public.transactions t
    where t.deleted_at is null and t.group_id = %L
      and (t.transaction_date, t.created_at, t.id) < (%L::date, %L::timestamptz, %L::uuid)
    order by t.transaction_date desc, t.created_at desc, t.id desc
    limit 31$q$, g, c_date, c_created, c_id)
  loop
    v_plan := coalesce(v_plan || ' / ', '') || btrim(r."QUERY PLAN");
  end loop;

  raise exception 'BENCH: % || PLAN: %', v_report, v_plan;
end
$$;
