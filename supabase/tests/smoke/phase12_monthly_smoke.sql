-- Phase 12 monthly-processing smoke test. One DO block that always ends with
-- an exception, so everything is rolled back. Success = 'SMOKE_OK: ...'.
--
--   npx supabase db query --linked -f supabase/tests/smoke/phase12_monthly_smoke.sql

do $$
declare
  ga uuid := gen_random_uuid();  ma uuid := gen_random_uuid();
  md uuid := gen_random_uuid();  me uuid := gen_random_uuid();
  mx uuid := gen_random_uuid();
  g1 uuid; g2 uuid;
  v_json jsonb; v_int integer; v_text text; v_state text;
  ms record;
  v_tx_before integer;
  v_passed integer := 0;
begin
  ---------------------------------------------------------------- setup
  insert into auth.users (id, email, raw_user_meta_data) values
    (ga, 'm_ga@users.hisaably.invalid', '{"username":"m_ga"}'),
    (ma, 'm_ma@users.hisaably.invalid', '{"username":"m_ma"}'),
    (md, 'm_md@users.hisaably.invalid', '{"username":"m_md"}'),
    (me, 'm_me@users.hisaably.invalid', '{"username":"m_me"}'),
    (mx, 'm_mx@users.hisaably.invalid', '{"username":"m_mx"}');
  update public.profiles set status = 'DISABLED' where id = md;

  insert into public.groups (name) values ('M Group 1') returning id into g1;
  insert into public.groups (name) values ('M Group 2') returning id into g2;
  insert into public.group_members (group_id, user_id, group_role) values
    (g1, ga, 'GROUP_ADMIN'), (g1, ma, 'MEMBER'), (g1, md, 'MEMBER'), (g1, me, 'MEMBER'),
    (g2, mx, 'MEMBER');
  update public.group_members set status = 'DISABLED' where group_id = g1 and user_id = me;

  insert into public.transactions (id, group_id, type, amount, category, transaction_date) values
    (gen_random_uuid(), g1, 'INCOME', 1000, null, date '2026-08-10'),
    (gen_random_uuid(), g1, 'INCOME', 500, null, date '2026-09-05'),
    (gen_random_uuid(), g1, 'EXPENSE', 200, 'Food', date '2026-09-20'),
    (gen_random_uuid(), g1, 'EXPENSE', 50, 'Food', date '2026-10-01'),
    (gen_random_uuid(), g2, 'INCOME', 70, null, date '2026-09-01');
  update public.groups set status = 'DISABLED' where id = g2;
  select count(*) into v_tx_before from public.transactions;

  ---------------------------------------------------------------- 1. first run
  v_json := public.run_monthly_processing(date '2026-10-15');
  if v_json ->> 'month' <> '2026-10-01' then
    raise exception 'FAIL 1a: month normalised: %', v_json;
  end if;
  select * into ms from public.monthly_summaries where group_id = g1 and year = 2026 and month = 9;
  if ms is null or ms.opening_balance <> 1000 or ms.total_income <> 500
     or ms.total_expense <> 200 or ms.closing_balance <> 1300 then
    raise exception 'FAIL 1b: September summary %', row_to_json(ms);
  end if;
  v_passed := v_passed + 1;

  -- 2. disabled group: no summary, no notifications.
  select count(*) into v_int from public.monthly_summaries where group_id = g2;
  if v_int <> 0 then raise exception 'FAIL 2a: disabled group summarised'; end if;
  select count(*) into v_int from public.notifications where group_id = g2;
  if v_int <> 0 then raise exception 'FAIL 2b: disabled group notified'; end if;
  v_passed := v_passed + 1;

  -- 3. recipients: active members with active profiles only.
  select string_agg(recipient_id::text, ',' order by recipient_id::text) into v_text
  from public.notifications where group_id = g1 and type = 'MONTH_STARTED';
  if v_text is distinct from (select string_agg(x::text, ',' order by x::text) from unnest(array[ga, ma]) x) then
    raise exception 'FAIL 3: recipients %', v_text;
  end if;
  v_passed := v_passed + 1;

  -- 4. content: previous closing = new opening, INR formatted.
  select title || ' | ' || body into v_text
  from public.notifications where group_id = g1 and recipient_id = ma;
  if v_text <> 'New Month Started — October 2026 | M Group 1 • Closing (Sep) ₹1,300 • Opening (Oct) ₹1,300' then
    raise exception 'FAIL 4: text %', v_text;
  end if;
  v_passed := v_passed + 1;

  ---------------------------------------------------------------- 5. idempotent
  v_json := public.run_monthly_processing(date '2026-10-01');
  select count(*) into v_int from public.notifications where group_id = g1;
  if v_int <> 2 then raise exception 'FAIL 5a: % notifications after re-run', v_int; end if;
  select count(*) into v_int from public.monthly_summaries where group_id = g1;
  if v_int <> 1 then raise exception 'FAIL 5b: % summary rows', v_int; end if;
  v_passed := v_passed + 1;

  -- 6. backdated entry → re-run refreshes the cache, still no duplicates.
  insert into public.transactions (id, group_id, type, amount, category, transaction_date)
  values (gen_random_uuid(), g1, 'EXPENSE', 100, 'Rent', date '2026-09-28');
  perform public.run_monthly_processing(date '2026-10-01');
  select closing_balance into v_text from public.monthly_summaries
   where group_id = g1 and year = 2026 and month = 9;
  if v_text::numeric <> 1200 then raise exception 'FAIL 6a: closing %', v_text; end if;
  select count(*) into v_int from public.notifications where group_id = g1;
  if v_int <> 2 then raise exception 'FAIL 6b: duplicates (%)', v_int; end if;
  v_passed := v_passed + 1;

  -- 7. no carry-forward rows were written to transactions.
  select count(*) into v_int from public.transactions;
  if v_int <> v_tx_before + 1 then
    raise exception 'FAIL 7: transactions changed by the job (% vs %)', v_int, v_tx_before + 1;
  end if;
  v_passed := v_passed + 1;

  -- 8. without a month it only acts on the 1st (IST).
  v_json := public.run_monthly_processing();
  if extract(day from public.ist_today()) <> 1 and v_json ->> 'skipped' is null then
    raise exception 'FAIL 8a: ran on day %', extract(day from public.ist_today());
  end if;
  if extract(day from public.ist_today()) = 1 and v_json ->> 'month' is null then
    raise exception 'FAIL 8b: did not run on the 1st: %', v_json;
  end if;
  v_passed := v_passed + 1;

  -- 9. clients cannot run it.
  perform set_config('request.jwt.claims', json_build_object('sub', ga, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  begin
    perform public.run_monthly_processing(date '2026-10-01');
    raise exception 'FAIL 9: authenticated could run the job';
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'none', true);
  v_passed := v_passed + 1;

  -- 10. scheduled at 00:05 IST daily.
  select schedule into v_text from cron.job where jobname = 'hisaably-monthly';
  if v_text is distinct from '35 18 * * *' then raise exception 'FAIL 10: schedule %', v_text; end if;
  v_passed := v_passed + 1;

  raise exception 'SMOKE_OK: % checks passed (all changes rolled back)', v_passed;
end
$$;
