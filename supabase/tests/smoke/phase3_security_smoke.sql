-- Phase 3 security & business-rule smoke test (role impersonation).
-- Everything runs in ONE DO block that always ends with an exception, so all
-- test data is rolled back. Success = final message 'SMOKE_OK: ...'.
--
--   npx supabase db query --linked -f supabase/tests/smoke/phase3_security_smoke.sql
--
-- Actors: SA (super admin), GA (group admin of G1), MA/MB (members of G1),
-- MC (member of G2), MD (DISABLED user, member of G1).

do $$
declare
  sa uuid := gen_random_uuid();  ga uuid := gen_random_uuid();
  ma uuid := gen_random_uuid();  mb uuid := gen_random_uuid();
  mc uuid := gen_random_uuid();  md uuid := gen_random_uuid();
  g1 uuid; g2 uuid; g3 uuid;
  tx1 uuid := gen_random_uuid();  tx_g2 uuid := gen_random_uuid();
  v_json jsonb; v_int integer; v_num numeric; v_text text; v_bool boolean;
  v_hint text; v_msg text; v_state text;
  v_passed integer := 0;
  v_extra uuid;
  r record;
  i integer;
  c_date date; c_created timestamptz; c_id uuid;
  v_future date := public.ist_today() + 1;
begin
  ---------------------------------------------------------------- setup (as owner)
  insert into auth.users (id, email, raw_user_meta_data) values
    (sa, 't_sa@users.hisaably.invalid', '{"username":"t_sa"}'),
    (ga, 't_ga@users.hisaably.invalid', '{"username":"t_ga"}'),
    (ma, 't_ma@users.hisaably.invalid', '{"username":"t_ma"}'),
    (mb, 't_mb@users.hisaably.invalid', '{"username":"t_mb"}'),
    (mc, 't_mc@users.hisaably.invalid', '{"username":"t_mc"}'),
    (md, 't_md@users.hisaably.invalid', '{"username":"t_md"}');
  update public.profiles set role = 'SUPER_ADMIN' where id = sa;
  update public.profiles set status = 'DISABLED' where id = md;

  insert into public.groups (name) values ('T Group 1') returning id into g1;
  insert into public.groups (name) values ('T Group 2') returning id into g2;
  insert into public.group_members (group_id, user_id, group_role) values
    (g1, ga, 'GROUP_ADMIN'), (g1, ma, 'MEMBER'), (g1, mb, 'MEMBER'), (g1, md, 'MEMBER'),
    (g2, mc, 'MEMBER');
  insert into public.transactions (id, group_id, type, amount, category, transaction_date)
  values (tx_g2, g2, 'EXPENSE', 999, 'Food', date '2026-09-01');

  -- ============================== MEMBER A
  perform set_config('request.jwt.claims', json_build_object('sub', ma, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- 1. context
  v_json := public.get_my_context();
  if v_json #>> '{profile,role}' <> 'USER' or jsonb_array_length(v_json -> 'memberships') <> 1 then
    raise exception 'FAIL 1: context %', v_json;
  end if;
  v_passed := v_passed + 1;

  -- 2. group isolation (RLS)
  select count(*) into v_int from public.groups;
  if v_int <> 1 then raise exception 'FAIL 2a: sees % groups', v_int; end if;
  select count(*) into v_int from public.transactions where group_id = g2;
  if v_int <> 0 then raise exception 'FAIL 2b: sees other group transactions'; end if;
  select count(*) into v_int from public.profiles where id = mc;
  if v_int <> 0 then raise exception 'FAIL 2c: sees unrelated profile'; end if;
  select count(*) into v_int from public.profiles where id = mb;
  if v_int <> 1 then raise exception 'FAIL 2d: cannot see fellow member'; end if;
  v_passed := v_passed + 1;

  -- 3. forbidden RPCs for a member
  foreach v_text in array array[
    'upsert_g2', 'update_tx', 'delete_tx', 'add_member', 'set_role', 'rename_group',
    'set_status', 'dashboard_g2', 'admin_overview', 'create_group'
  ] loop
    begin
      case v_text
        when 'upsert_g2' then perform public.upsert_transaction(gen_random_uuid(), g2, 'EXPENSE', 10, 'Food', null, date '2026-09-01');
        when 'update_tx' then perform public.update_transaction(tx_g2, 'EXPENSE', 10, 'Food', null, date '2026-09-01');
        when 'delete_tx' then perform public.delete_transaction(tx_g2);
        when 'add_member' then perform public.add_group_member(g1, mc);
        when 'set_role' then perform public.set_group_member_role(g1, ma, 'GROUP_ADMIN');
        when 'rename_group' then perform public.rename_group(g1, 'Hacked');
        when 'set_status' then perform public.set_group_member_status(g1, mb, 'DISABLED');
        when 'dashboard_g2' then perform public.get_dashboard(g2);
        when 'admin_overview' then perform public.get_admin_overview();
        when 'create_group' then perform public.create_group('Nope');
      end case;
      raise exception 'FAIL 3: member allowed %', v_text;
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
      if v_msg like 'FAIL%' then raise; end if;
      if v_hint not in ('FORBIDDEN', 'NOT_FOUND') then
        raise exception 'FAIL 3: % gave % / %', v_text, v_hint, v_msg;
      end if;
    end;
  end loop;
  v_passed := v_passed + 1;

  -- 4. direct table writes are impossible (no privileges at all)
  foreach v_text in array array['insert_tx', 'update_role', 'update_member_role', 'delete_tx'] loop
    begin
      case v_text
        when 'insert_tx' then insert into public.transactions (group_id, type, amount, category, transaction_date) values (g1, 'EXPENSE', 1, 'Food', date '2026-09-01');
        when 'update_role' then update public.profiles set role = 'SUPER_ADMIN' where id = ma;
        when 'update_member_role' then update public.group_members set group_role = 'GROUP_ADMIN' where user_id = ma;
        when 'delete_tx' then delete from public.transactions;
      end case;
      raise exception 'FAIL 4: direct % allowed', v_text;
    exception when insufficient_privilege then null;
    end;
  end loop;
  v_passed := v_passed + 1;

  -- 5. add expense + idempotent retry
  v_json := public.upsert_transaction(tx1, g1, 'EXPENSE', 850, 'food', ' Lunch ', date '2026-09-26');
  if (v_json ->> 'created')::boolean is not true then raise exception 'FAIL 5a: %', v_json; end if;
  if v_json #>> '{transaction,category}' <> 'Food' then raise exception 'FAIL 5b: category not canonical'; end if;
  v_json := public.upsert_transaction(tx1, g1, 'EXPENSE', 850, 'Food', 'Lunch', date '2026-09-26');
  if (v_json ->> 'created')::boolean is not false then raise exception 'FAIL 5c: retry created again'; end if;
  select count(*) into v_int from public.transactions where group_id = g1;
  if v_int <> 1 then raise exception 'FAIL 5d: % rows after retry', v_int; end if;
  v_passed := v_passed + 1;

  -- 6. future date rejected; bad amounts rejected
  foreach v_text in array array['future', 'zero', 'decimals', 'no_category'] loop
    begin
      case v_text
        when 'future' then perform public.upsert_transaction(gen_random_uuid(), g1, 'EXPENSE', 10, 'Food', null, v_future);
        when 'zero' then perform public.upsert_transaction(gen_random_uuid(), g1, 'EXPENSE', 0, 'Food', null, date '2026-09-01');
        when 'decimals' then perform public.upsert_transaction(gen_random_uuid(), g1, 'EXPENSE', 1.005, 'Food', null, date '2026-09-01');
        when 'no_category' then perform public.upsert_transaction(gen_random_uuid(), g1, 'EXPENSE', 5, '  ', null, date '2026-09-01');
      end case;
      raise exception 'FAIL 6: % accepted', v_text;
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
      if v_msg like 'FAIL%' then raise; end if;
      if v_hint not in ('FUTURE_DATE', 'VALIDATION') then raise exception 'FAIL 6: % gave %', v_text, v_msg; end if;
    end;
  end loop;
  v_passed := v_passed + 1;

  -- 7. "Other" category is created for this group only
  perform public.upsert_transaction(gen_random_uuid(), g1, 'EXPENSE', 300, 'Pets', null, date '2026-09-27');
  select count(*) into v_int from public.group_categories where group_id = g1 and name = 'Pets';
  if v_int <> 1 then raise exception 'FAIL 7a: Pets not created'; end if;
  v_passed := v_passed + 1;

  -- 8. actor gets no notification of their own transaction
  select count(*) into v_int from public.notifications;
  if v_int <> 0 then raise exception 'FAIL 8a: actor notified'; end if;
  v_passed := v_passed + 1;

  ---------------------------------------------------------------- owner checks
  perform set_config('role', 'none', true);
  -- recipients: GA and MB only (not actor MA, not disabled MD, not other group's MC)
  select count(*) into v_int from public.notifications where transaction_id = tx1;
  if v_int <> 2 then raise exception 'FAIL 9a: % notifications for tx1', v_int; end if;
  if exists (select 1 from public.notifications where transaction_id = tx1 and recipient_id in (ma, md, mc)) then
    raise exception 'FAIL 9b: wrong recipient';
  end if;
  select body into v_text from public.notifications where transaction_id = tx1 limit 1;
  if v_text <> '₹850 • Food • 26 Sep' then raise exception 'FAIL 9c: body "%"', v_text; end if;
  if exists (select 1 from public.group_categories where group_id = g2 and name = 'Pets') then
    raise exception 'FAIL 9d: Pets leaked to G2';
  end if;
  v_passed := v_passed + 1;

  -- ============================== GROUP ADMIN
  perform set_config('request.jwt.claims', json_build_object('sub', ga, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- 10. rename own group ok; other group forbidden
  perform public.rename_group(g1, 'T Group One');
  begin
    perform public.rename_group(g2, 'Nope');
    raise exception 'FAIL 10: GA renamed other group';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
  end;
  v_passed := v_passed + 1;

  -- 11. edit with optimistic concurrency; stale version -> CONFLICT
  v_json := public.update_transaction(tx1, 'EXPENSE', 900, 'Food', 'Lunch+tip', date '2026-09-26', 1);
  if (v_json ->> 'sync_version')::bigint <> 2 then raise exception 'FAIL 11a: %', v_json; end if;
  begin
    perform public.update_transaction(tx1, 'EXPENSE', 950, 'Food', null, date '2026-09-26', 1);
    raise exception 'FAIL 11b: stale edit accepted';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
    if v_hint <> 'CONFLICT' then raise exception 'FAIL 11b: got %', v_hint; end if;
  end;
  v_passed := v_passed + 1;

  -- 12. GA can disable a plain member but not themselves; can't add/remove
  perform public.set_group_member_status(g1, mb, 'DISABLED');
  foreach v_text in array array['self', 'add', 'remove', 'set_role'] loop
    begin
      case v_text
        when 'self' then perform public.set_group_member_status(g1, ga, 'DISABLED');
        when 'add' then perform public.add_group_member(g1, mc);
        when 'remove' then perform public.remove_group_member(g1, ma);
        when 'set_role' then perform public.set_group_member_role(g1, ma, 'GROUP_ADMIN');
      end case;
      raise exception 'FAIL 12: GA allowed %', v_text;
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
      if v_msg like 'FAIL%' then raise; end if;
      if v_hint <> 'FORBIDDEN' then raise exception 'FAIL 12: % gave %', v_text, v_hint; end if;
    end;
  end loop;
  v_passed := v_passed + 1;

  -- 13. category rename cascades to past transactions; delete hides it
  select id into v_extra from public.group_categories where group_id = g1 and name = 'Pets';
  perform public.rename_group_category(v_extra, 'Animals');
  select count(*) into v_int from public.transactions where group_id = g1 and category = 'Animals';
  if v_int <> 1 then raise exception 'FAIL 13a: rename did not cascade'; end if;
  perform public.delete_group_category(v_extra);
  select count(*) into v_int from public.transactions where group_id = g1 and category = 'Animals';
  if v_int <> 1 then raise exception 'FAIL 13b: delete touched transactions'; end if;
  select is_active into v_bool from public.group_categories where id = v_extra;
  if v_bool then raise exception 'FAIL 13c: category still active'; end if;
  v_passed := v_passed + 1;

  -- 14. soft delete
  perform public.delete_transaction(tx1);
  perform public.delete_transaction(tx1);  -- idempotent
  select count(*) into v_int from public.list_transactions(g1);
  if v_int <> 1 then raise exception 'FAIL 14: deleted tx listed (% rows)', v_int; end if;
  v_passed := v_passed + 1;

  -- ============================== DISABLED MEMBER (membership)
  perform set_config('request.jwt.claims', json_build_object('sub', mb, 'role', 'authenticated')::text, true);
  select count(*) into v_int from public.groups;
  if v_int <> 0 then raise exception 'FAIL 15a: disabled member sees group'; end if;
  begin
    perform public.upsert_transaction(gen_random_uuid(), g1, 'INCOME', 5, null, null, date '2026-09-01');
    raise exception 'FAIL 15b: disabled member added tx';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
  end;
  v_passed := v_passed + 1;

  -- ============================== DISABLED USER (profile)
  perform set_config('request.jwt.claims', json_build_object('sub', md, 'role', 'authenticated')::text, true);
  v_json := public.get_my_context();
  if v_json #>> '{profile,status}' <> 'DISABLED' then raise exception 'FAIL 16a'; end if;
  select count(*) into v_int from public.transactions;
  if v_int <> 0 then raise exception 'FAIL 16b: disabled user reads data'; end if;
  begin
    perform public.upsert_transaction(gen_random_uuid(), g1, 'INCOME', 5, null, null, date '2026-09-01');
    raise exception 'FAIL 16c: disabled user wrote';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
    if v_hint <> 'ACCOUNT_DISABLED' then raise exception 'FAIL 16c: got %', v_hint; end if;
  end;
  v_passed := v_passed + 1;

  -- ============================== SUPER ADMIN
  perform set_config('request.jwt.claims', json_build_object('sub', sa, 'role', 'authenticated')::text, true);

  -- 17. assign Group Admin; then GA cannot disable another Group Admin
  perform public.set_group_member_status(g1, mb, 'ACTIVE');
  perform public.set_group_member_role(g1, mb, 'GROUP_ADMIN');
  perform set_config('request.jwt.claims', json_build_object('sub', ga, 'role', 'authenticated')::text, true);
  begin
    perform public.set_group_member_status(g1, mb, 'DISABLED');
    raise exception 'FAIL 17: GA disabled another GA';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', sa, 'role', 'authenticated')::text, true);
  v_passed := v_passed + 1;

  -- 18. add member + duplicate + 10-member limit via RPC
  perform public.add_group_member(g2, ma);
  begin
    perform public.add_group_member(g2, ma);
    raise exception 'FAIL 18a: duplicate add';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
    if v_hint <> 'ALREADY_MEMBER' then raise exception 'FAIL 18a: got %', v_hint; end if;
  end;
  perform set_config('role', 'none', true);
  for i in 1..9 loop
    insert into auth.users (id, email, raw_user_meta_data)
    values (gen_random_uuid(), format('t_x%s@users.hisaably.invalid', i),
            jsonb_build_object('username', format('t_x%s', i)));
  end loop;
  perform set_config('role', 'authenticated', true);
  for r in select id from public.profiles where username like 't\_x%' order by username loop
    begin
      perform public.add_group_member(g2, r.id);
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      if v_hint <> 'GROUP_MEMBER_LIMIT' then raise; end if;
      v_state := 'limited';
    end;
  end loop;
  select count(*) into v_int from public.group_members where group_id = g2 and status = 'ACTIVE';
  if v_int <> 10 or v_state is distinct from 'limited' then
    raise exception 'FAIL 18b: % active, state %', v_int, v_state;
  end if;
  v_passed := v_passed + 1;

  -- 19. monthly balances with carry-forward and a backdated entry
  g3 := (public.create_group('T Ledger')).id;
  select count(*) into v_int from public.group_categories where group_id = g3;
  if v_int <> 11 then raise exception 'FAIL 19a: % categories', v_int; end if;
  perform public.upsert_transaction(gen_random_uuid(), g3, 'INCOME', 50000, 'Contribution', null, date '2026-08-10');
  perform public.upsert_transaction(gen_random_uuid(), g3, 'EXPENSE', 35000, 'Rent', null, date '2026-08-12');
  perform public.upsert_transaction(gen_random_uuid(), g3, 'INCOME', 20000, null, null, date '2026-09-05');
  perform public.upsert_transaction(gen_random_uuid(), g3, 'EXPENSE', 10000, 'Food', null, date '2026-09-09');
  select closing_balance into v_num from public.get_monthly_balances(g3, date '2026-08-01', date '2026-09-01') where month_start = date '2026-08-01';
  if v_num <> 15000 then raise exception 'FAIL 19b: Aug closing %', v_num; end if;
  select opening_balance into v_num from public.get_monthly_balances(g3, date '2026-08-01', date '2026-09-01') where month_start = date '2026-09-01';
  if v_num <> 15000 then raise exception 'FAIL 19c: Sep opening %', v_num; end if;
  -- backdated expense into August
  perform public.upsert_transaction(gen_random_uuid(), g3, 'EXPENSE', 1000, 'Food', null, date '2026-08-20');
  select opening_balance into v_num from public.get_monthly_balances(g3, date '2026-09-01', date '2026-09-01');
  if v_num <> 14000 then raise exception 'FAIL 19d: Sep opening after backdate %', v_num; end if;
  v_json := public.get_dashboard(g3, date '2026-09-01');
  if (v_json ->> 'current_balance')::numeric <> 24000
     or (v_json #>> '{month_summary,closing_balance}')::numeric <> 24000
     or (v_json #>> '{month_summary,total_expense}')::numeric <> 10000
     or jsonb_array_length(v_json -> 'trend') <> 6 then
    raise exception 'FAIL 19e: dashboard %', v_json;
  end if;
  v_passed := v_passed + 1;

  -- 20. keyset pagination over 5 transactions, page size 2
  select count(*) into v_int from public.list_transactions(g3, p_limit => 2);
  if v_int <> 2 then raise exception 'FAIL 20a'; end if;
  v_int := 0; c_date := null;
  loop
    select count(*), min(transaction_date) into i, v_text
    from public.list_transactions(g3, p_cursor_date => c_date, p_cursor_created_at => c_created, p_cursor_id => c_id, p_limit => 2);
    exit when i = 0;
    v_int := v_int + i;
    select t.transaction_date, t.created_at, t.id into c_date, c_created, c_id
    from public.list_transactions(g3, p_cursor_date => c_date, p_cursor_created_at => c_created, p_cursor_id => c_id, p_limit => 2) t
    order by t.transaction_date, t.created_at, t.id limit 1;
  end loop;
  if v_int <> 5 then raise exception 'FAIL 20b: paged % rows', v_int; end if;
  v_passed := v_passed + 1;

  -- 21. All-groups dashboard and admin overview
  v_json := public.get_dashboard(null, date '2026-09-01');
  if jsonb_array_length(v_json -> 'group_ids') < 3 then raise exception 'FAIL 21a'; end if;
  v_json := public.get_admin_overview();
  if (v_json ->> 'users_disabled')::int < 1 then raise exception 'FAIL 21b: %', v_json; end if;
  v_passed := v_passed + 1;

  -- 22. disabled group blocks its members
  perform public.set_group_status(g2, 'DISABLED');
  perform set_config('request.jwt.claims', json_build_object('sub', mc, 'role', 'authenticated')::text, true);
  select count(*) into v_int from public.groups;
  if v_int <> 0 then raise exception 'FAIL 22: member sees disabled group'; end if;
  v_passed := v_passed + 1;

  -- ============================== ANON
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role', 'anon', true);
  begin
    select count(*) into v_int from public.transactions;
    raise exception 'FAIL 23: anon can read transactions';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.get_my_context();
    raise exception 'FAIL 23b: anon can call RPC';
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'none', true);
  v_passed := v_passed + 1;

  -- 24b. No function in public is executable by PUBLIC or anon; internal
  --      helpers are not executable by authenticated.
  select string_agg(p.proname, ', ') into v_text
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.prokind = 'f'
    and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or (p.proname in ('ensure_group_category', 'resolve_visible_groups', 'raise_app_error',
                           'require_active_user', 'require_super_admin', 'normalize_name',
                           'validate_transaction_fields', 'format_inr', 'ist_today',
                           'handle_new_auth_user', 'enforce_group_member_limit',
                           'seed_group_categories', 'transactions_before_write', 'set_updated_at',
                           'dispatch_push_notifications', 'run_monthly_processing')
             and has_function_privilege('authenticated', p.oid, 'EXECUTE')));
  if v_text is not null then raise exception 'FAIL 24b: over-exposed functions: %', v_text; end if;
  v_passed := v_passed + 1;

  -- 24. INR formatting
  if public.format_inr(20000) <> '₹20,000' or public.format_inr(1850000) <> '₹18,50,000'
     or public.format_inr(1234.5) <> '₹1,234.50' or public.format_inr(850) <> '₹850' then
    raise exception 'FAIL 24: format_inr';
  end if;
  v_passed := v_passed + 1;

  raise exception 'SMOKE_OK: % checks passed (all changes rolled back)', v_passed;
end;
$$;
