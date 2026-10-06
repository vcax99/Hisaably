-- Entry history ("Added by" / "Edited by") and notification cleanup smoke
-- test. One DO block that always ends with an exception, so everything is
-- rolled back. Success = 'SMOKE_OK: ...'.
--
--   npx supabase db query --linked -f supabase/tests/smoke/phase16_history_notifications_smoke.sql

do $$
declare
  ga uuid := gen_random_uuid();  ma uuid := gen_random_uuid();
  mb uuid := gen_random_uuid();  mx uuid := gen_random_uuid();
  g1 uuid; g2 uuid;
  tx1 uuid := gen_random_uuid();  tx_old uuid := gen_random_uuid();
  tx2 uuid := gen_random_uuid();  tx3 uuid := gen_random_uuid();
  tx4 uuid := gen_random_uuid();
  v_case text;
  n_ma uuid; n_ga uuid;
  v_json jsonb; v_int integer; v_text text; v_hint text; v_msg text;
  v_today date := public.ist_today();
  v_passed integer := 0;
begin
  ---------------------------------------------------------------- setup
  insert into auth.users (id, email, raw_user_meta_data) values
    (ga, 'h_ga@users.hisaably.invalid', '{"username":"h_ga","name":"Hist Admin"}'),
    (ma, 'h_ma@users.hisaably.invalid', '{"username":"h_ma","name":"Hist Member A"}'),
    (mb, 'h_mb@users.hisaably.invalid', '{"username":"h_mb","name":"Hist Member B"}'),
    (mx, 'h_mx@users.hisaably.invalid', '{"username":"h_mx","name":"Hist Outsider"}');
  update public.profiles set name = 'Hist Admin' where id = ga;
  update public.profiles set name = 'Hist Member A' where id = ma;
  update public.profiles set name = 'Hist Member B' where id = mb;

  insert into public.groups (name) values ('H Group 1') returning id into g1;
  insert into public.groups (name) values ('H Group 2') returning id into g2;
  insert into public.group_members (group_id, user_id, group_role) values
    (g1, ga, 'GROUP_ADMIN'), (g1, ma, 'MEMBER'), (g1, mb, 'MEMBER'), (g2, mx, 'MEMBER');

  -- An entry from before history existed (no signed-in caller → not recorded).
  insert into public.transactions (id, group_id, type, amount, category, transaction_date)
  values (tx_old, g1, 'EXPENSE', 100, 'Food', v_today);
  if exists (select 1 from public.transaction_history where transaction_id = tx_old) then
    raise exception 'FAIL 1: script insert was attributed';
  end if;
  v_passed := v_passed + 1;

  -- ============================== MEMBER A adds
  perform set_config('request.jwt.claims', json_build_object('sub', ma, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- 2. add → CREATED by MA; retry → no second record
  perform public.upsert_transaction(tx1, g1, 'EXPENSE', 850, 'Food', 'Lunch', v_today);
  perform public.upsert_transaction(tx1, g1, 'EXPENSE', 850, 'Food', 'Lunch', v_today);
  v_json := public.get_transaction_history(tx1);
  if v_json #>> '{created,name}' is distinct from 'Hist Member A' or v_json -> 'updated' <> 'null'::jsonb then
    raise exception 'FAIL 2: %', v_json;
  end if;
  v_passed := v_passed + 1;

  -- 3. clients can't read the history table directly
  begin
    perform 1 from public.transaction_history;
    raise exception 'FAIL 3: history table readable';
  exception when insufficient_privilege then null;
  end;
  v_passed := v_passed + 1;

  -- 4. old entry: created is null
  v_json := public.get_transaction_history(tx_old);
  if v_json -> 'created' <> 'null'::jsonb then raise exception 'FAIL 4: %', v_json; end if;
  v_passed := v_passed + 1;

  -- 4b. decision 16: a member edits/deletes only entries they added
  perform public.upsert_transaction(tx2, g1, 'EXPENSE', 200, 'Food', 'Mine', v_today);
  perform public.upsert_transaction(tx4, g1, 'EXPENSE', 400, 'Food', 'Mine too', v_today);
  perform set_config('request.jwt.claims', json_build_object('sub', mb, 'role', 'authenticated')::text, true);
  perform public.upsert_transaction(tx3, g1, 'EXPENSE', 300, 'Food', 'Not hers', v_today);
  perform set_config('request.jwt.claims', json_build_object('sub', ma, 'role', 'authenticated')::text, true);
  if (public.get_transaction_history(tx2) ->> 'can_edit')::boolean is not true
     or (public.get_transaction_history(tx3) ->> 'can_edit')::boolean is not false
     or (public.get_transaction_history(tx_old) ->> 'can_edit')::boolean is not false then
    raise exception 'FAIL 4b: can_edit flags';
  end if;
  perform public.update_transaction(tx2, 'EXPENSE', 250, 'Food', 'Mine', v_today);
  foreach v_case in array array['update_other', 'delete_other', 'delete_unrecorded'] loop
    begin
      case v_case
        when 'update_other' then perform public.update_transaction(tx3, 'EXPENSE', 1, 'Food', null, v_today);
        when 'delete_other' then perform public.delete_transaction(tx3);
        when 'delete_unrecorded' then perform public.delete_transaction(tx_old);
      end case;
      raise exception 'FAIL 4b: member could %', v_case;
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
      if v_msg like 'FAIL%' then raise; end if;
      if v_hint <> 'FORBIDDEN' then raise exception 'FAIL 4b: % gave %', v_case, v_msg; end if;
    end;
  end loop;
  if (select amount from public.transactions where id = tx2) <> 250 then
    raise exception 'FAIL 4c: own edit not applied';
  end if;
  perform public.delete_transaction(tx2);
  perform set_config('role', 'none', true);
  if exists (select 1 from public.transactions where id = tx2) then
    raise exception 'FAIL 4c: own delete not applied';
  end if;
  -- a disabled membership loses the right, even for own entries
  update public.group_members set status = 'DISABLED' where group_id = g1 and user_id = ma;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.update_transaction(tx4, 'EXPENSE', 1, 'Food', null, v_today);
    raise exception 'FAIL 4d: disabled member edited';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
    if v_hint <> 'FORBIDDEN' then raise exception 'FAIL 4d: %', v_msg; end if;
  end;
  perform set_config('role', 'none', true);
  update public.group_members set status = 'ACTIVE' where group_id = g1 and user_id = ma;
  perform set_config('role', 'authenticated', true);
  v_passed := v_passed + 1;

  -- ============================== GROUP ADMIN edits
  perform set_config('request.jwt.claims', json_build_object('sub', ga, 'role', 'authenticated')::text, true);

  -- 5. real edit → UPDATED by GA; saving identical values → nothing new
  perform public.update_transaction(tx1, 'EXPENSE', 900, 'Food', 'Lunch', v_today);
  perform public.update_transaction(tx1, 'EXPENSE', 900, 'Food', 'Lunch', v_today);
  v_json := public.get_transaction_history(tx1);
  if v_json #>> '{created,name}' is distinct from 'Hist Member A'
     or v_json #>> '{updated,name}' is distinct from 'Hist Admin' then
    raise exception 'FAIL 5a: %', v_json;
  end if;
  perform set_config('role', 'none', true);
  select count(*) into v_int from public.transaction_history where transaction_id = tx1 and action = 'UPDATED';
  if v_int <> 1 then raise exception 'FAIL 5b: % UPDATED rows', v_int; end if;
  perform set_config('role', 'authenticated', true);
  v_passed := v_passed + 1;

  -- 6. renaming a category rewrites entries but isn't an edit
  perform public.rename_group_category(
    (select id from public.group_categories where group_id = g1 and type = 'EXPENSE' and name = 'Food'),
    'Meals');
  perform set_config('role', 'none', true);
  if (select category from public.transactions where id = tx1) <> 'Meals' then
    raise exception 'FAIL 6a: rename did not cascade';
  end if;
  select count(*) into v_int from public.transaction_history where action = 'UPDATED' and transaction_id = tx1;
  if v_int <> 1 then raise exception 'FAIL 6b: rename recorded as edit (% rows)', v_int; end if;
  perform set_config('role', 'authenticated', true);
  v_passed := v_passed + 1;

  -- 7. delete → DELETED record
  perform public.delete_transaction(tx_old);
  perform set_config('role', 'none', true);
  if exists (select 1 from public.transactions where id = tx_old)
     or not exists (select 1 from public.deleted_transactions where id = tx_old) then
    raise exception 'FAIL 7: not hard-deleted';
  end if;
  perform set_config('role', 'authenticated', true);
  v_passed := v_passed + 1;

  -- ============================== OUTSIDER
  perform set_config('request.jwt.claims', json_build_object('sub', mx, 'role', 'authenticated')::text, true);
  -- 8. another group's member can't read the history
  begin
    perform public.get_transaction_history(tx1);
    raise exception 'FAIL 8: outsider read history';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
    if v_hint <> 'NOT_FOUND' then raise exception 'FAIL 8: %', v_msg; end if;
  end;
  v_passed := v_passed + 1;

  -- 9. a deleted user shows as null name
  perform set_config('role', 'none', true);
  delete from auth.users where id = ma;
  perform set_config('request.jwt.claims', json_build_object('sub', ga, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  v_json := public.get_transaction_history(tx1);
  if v_json -> 'created' = 'null'::jsonb or v_json #> '{created,name}' <> 'null'::jsonb then
    raise exception 'FAIL 9: %', v_json;
  end if;
  v_passed := v_passed + 1;

  ---------------------------------------------------------------- notifications
  perform set_config('role', 'none', true);
  -- GA and MB were notified of tx1 (MA was the actor).
  select id into n_ga from public.notifications where recipient_id = ga limit 1;
  insert into public.notifications (group_id, recipient_id, type, title, body)
  values (g2, mx, 'EXPENSE_ADDED', 'Expense Added', '₹1 • Food • 1 Oct');

  -- 10. default retention is 7 days; settings RPCs validate
  perform set_config('role', 'authenticated', true);
  v_json := public.get_notification_settings();
  if (v_json ->> 'retention_days')::int is distinct from 7 then raise exception 'FAIL 10a: %', v_json; end if;
  begin
    perform public.set_notification_retention(30);
    raise exception 'FAIL 10b: 30 days accepted';
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if v_msg like 'FAIL%' then raise; end if;
    if v_hint <> 'VALIDATION' then raise exception 'FAIL 10b: %', v_msg; end if;
  end;
  perform public.set_notification_retention(15);
  if (public.get_notification_settings() ->> 'retention_days')::int <> 15 then raise exception 'FAIL 10c'; end if;
  perform public.set_notification_retention(null);
  if public.get_notification_settings() -> 'retention_days' <> 'null'::jsonb then raise exception 'FAIL 10d'; end if;
  perform public.set_notification_retention(7);
  v_passed := v_passed + 1;

  -- 11. marking read sets read_at
  perform public.mark_notification_read(n_ga);
  perform set_config('role', 'none', true);
  if (select read_at from public.notifications where id = n_ga) is null then raise exception 'FAIL 11'; end if;
  v_passed := v_passed + 1;

  -- 12. purge: past retention → gone; within retention, unread or "never" → kept
  update public.notifications set read_at = now() - interval '8 days' where id = n_ga;
  insert into public.notifications (group_id, recipient_id, type, title, body, is_read)
  values (g1, ga, 'EXPENSE_ADDED', 'Recent', 'x', true);                       -- read just now
  insert into public.notifications (group_id, recipient_id, type, title, body, created_at)
  values (g1, ga, 'EXPENSE_ADDED', 'Old unread', 'x', now() - interval '30 days');
  update public.profiles set notification_retention_days = null where id = mb;
  update public.notifications set is_read = true where recipient_id = mb;
  update public.notifications set read_at = now() - interval '40 days' where recipient_id = mb;
  perform public.purge_read_notifications();
  if exists (select 1 from public.notifications where id = n_ga) then raise exception 'FAIL 12a: not purged'; end if;
  if not exists (select 1 from public.notifications where recipient_id = ga and title = 'Recent') then
    raise exception 'FAIL 12b: recent read purged';
  end if;
  if not exists (select 1 from public.notifications where recipient_id = ga and title = 'Old unread') then
    raise exception 'FAIL 12c: unread purged';
  end if;
  if not exists (select 1 from public.notifications where recipient_id = mb) then
    raise exception 'FAIL 12d: "never" purged';
  end if;
  v_passed := v_passed + 1;

  -- 13. delete all: only the caller's notifications
  perform set_config('role', 'authenticated', true);
  v_int := public.delete_all_notifications();
  perform set_config('role', 'none', true);
  if v_int < 2 or exists (select 1 from public.notifications where recipient_id = ga) then
    raise exception 'FAIL 13a: % deleted', v_int;
  end if;
  if not exists (select 1 from public.notifications where recipient_id = mx)
     or not exists (select 1 from public.notifications where recipient_id = mb) then
    raise exception 'FAIL 13b: other users'' notifications deleted';
  end if;
  v_passed := v_passed + 1;

  -- 14. internal functions aren't callable by clients
  select string_agg(p.proname, ', ') into v_text
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname in ('record_transaction_history', 'notifications_set_read_at', 'purge_read_notifications')
    and (has_function_privilege('anon', p.oid, 'EXECUTE')
         or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  if v_text is not null then raise exception 'FAIL 14: exposed: %', v_text; end if;
  if not exists (select 1 from cron.job where jobname = 'hisaably-daily-cleanup') then
    raise exception 'FAIL 14b: cleanup job missing';
  end if;
  v_passed := v_passed + 1;

  raise exception 'SMOKE_OK: % checks passed (all changes rolled back)', v_passed;
end;
$$;
