-- Phase 2 schema smoke test.
-- Runs against the linked project WITHOUT leaving data behind: everything runs
-- inside one DO block that always ends by raising an exception, which rolls
-- back every change. Success = the final error message 'SMOKE_OK: ...'.
--
--   npx supabase db query --linked -f supabase/tests/smoke/phase2_schema_smoke.sql

do $$
declare
  v_users   uuid[] := array[]::uuid[];
  v_uid     uuid;
  v_group   uuid;
  v_tx      uuid := gen_random_uuid();
  v_count   integer;
  v_role    text;
  v_ver     bigint;
  v_email   text;
  v_passed  integer := 0;
  i         integer;
begin
  -- 1. Profile auto-created; metadata can't grant SUPER_ADMIN; synthetic email hidden.
  v_uid := gen_random_uuid();
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_uid, 'smoke_admin@users.hisaably.invalid',
          '{"username":"Smoke_Admin","name":"Smoke Admin","role":"SUPER_ADMIN"}');
  select role::text, email into v_role, v_email from public.profiles where id = v_uid;
  if v_role is distinct from 'USER' then raise exception 'FAIL 1: role=%', v_role; end if;
  if v_email is not null then raise exception 'FAIL 1: synthetic email stored'; end if;
  if not exists (select 1 from public.profiles where id = v_uid and username = 'smoke_admin') then
    raise exception 'FAIL 1: username not normalised';
  end if;
  v_passed := v_passed + 1;

  -- 2. Duplicate username rejected.
  begin
    insert into auth.users (id, email, raw_user_meta_data)
    values (gen_random_uuid(), 'x1@users.hisaably.invalid', '{"username":"smoke_admin"}');
    raise exception 'FAIL 2: duplicate username accepted';
  exception when unique_violation then v_passed := v_passed + 1;
  end;

  -- 3. Invalid username rejected.
  begin
    insert into auth.users (id, email, raw_user_meta_data)
    values (gen_random_uuid(), 'x2@users.hisaably.invalid', '{"username":"a b"}');
    raise exception 'FAIL 3: invalid username accepted';
  exception when check_violation then v_passed := v_passed + 1;
  end;

  -- 4. New group gets default categories (8 expense + 3 income).
  insert into public.groups (name) values ('Smoke Group') returning id into v_group;
  select count(*) into v_count from public.group_categories where group_id = v_group;
  if v_count <> 11 then raise exception 'FAIL 4: % categories', v_count; end if;
  v_passed := v_passed + 1;

  -- 5. 10-active-member limit.
  for i in 1..11 loop
    v_uid := gen_random_uuid();
    insert into auth.users (id, email, raw_user_meta_data)
    values (v_uid, format('smoke_m%s@users.hisaably.invalid', i),
            jsonb_build_object('username', format('smoke_m%s', i)));
    v_users := v_users || v_uid;
  end loop;
  for i in 1..10 loop
    insert into public.group_members (group_id, user_id) values (v_group, v_users[i]);
  end loop;
  begin
    insert into public.group_members (group_id, user_id) values (v_group, v_users[11]);
    raise exception 'FAIL 5a: 11th active member accepted';
  exception when check_violation then v_passed := v_passed + 1;
  end;
  -- A DISABLED 11th member is allowed, but enabling them is not.
  insert into public.group_members (group_id, user_id, status)
  values (v_group, v_users[11], 'DISABLED');
  begin
    update public.group_members set status = 'ACTIVE'
    where group_id = v_group and user_id = v_users[11];
    raise exception 'FAIL 5b: enabling 11th member accepted';
  exception when check_violation then v_passed := v_passed + 1;
  end;
  -- Disable one, then the 11th can be enabled.
  update public.group_members set status = 'DISABLED'
  where group_id = v_group and user_id = v_users[1];
  update public.group_members set status = 'ACTIVE'
  where group_id = v_group and user_id = v_users[11];
  v_passed := v_passed + 1;

  -- 6. Same user can't join the same group twice. (Inserted as DISABLED so the
  --    member-limit trigger doesn't fire first on this full group.)
  begin
    insert into public.group_members (group_id, user_id, status)
    values (v_group, v_users[2], 'DISABLED');
    raise exception 'FAIL 6: duplicate membership accepted';
  exception when unique_violation then v_passed := v_passed + 1;
  end;

  -- 7. Transaction rules.
  begin
    insert into public.transactions (group_id, type, amount, category, transaction_date)
    values (v_group, 'EXPENSE', 0, 'Food', public.ist_today());
    raise exception 'FAIL 7a: zero amount accepted';
  exception when check_violation then v_passed := v_passed + 1;
  end;
  begin
    insert into public.transactions (group_id, type, amount, category, transaction_date)
    values (v_group, 'EXPENSE', 10, 'Food', public.ist_today() + 1);
    raise exception 'FAIL 7b: future date accepted';
  exception when check_violation then v_passed := v_passed + 1;
  end;
  begin
    insert into public.transactions (group_id, type, amount, transaction_date)
    values (v_group, 'EXPENSE', 10, public.ist_today());
    raise exception 'FAIL 7c: expense without category accepted';
  exception when check_violation then v_passed := v_passed + 1;
  end;
  -- Backdated income without a category is fine.
  insert into public.transactions (id, group_id, type, amount, transaction_date)
  values (v_tx, v_group, 'INCOME', 50000.00, public.ist_today() - 30);
  -- Idempotent retry pattern: same client UUID does not create a second row.
  insert into public.transactions (id, group_id, type, amount, transaction_date)
  values (v_tx, v_group, 'INCOME', 50000.00, public.ist_today() - 30)
  on conflict (id) do nothing;
  select count(*) into v_count from public.transactions where group_id = v_group;
  if v_count <> 1 then raise exception 'FAIL 7d: % rows after retry', v_count; end if;
  -- Updates bump sync_version.
  update public.transactions set description = 'edited' where id = v_tx;
  select sync_version into v_ver from public.transactions where id = v_tx;
  if v_ver <> 2 then raise exception 'FAIL 7e: sync_version=%', v_ver; end if;
  v_passed := v_passed + 1;

  -- 8. monthly_summaries enforces Closing = Opening + Income - Expense.
  begin
    insert into public.monthly_summaries
      (group_id, year, month, opening_balance, total_income, total_expense, closing_balance)
    values (v_group, 2026, 9, 0, 50000, 35000, 99999);
    raise exception 'FAIL 8: wrong closing balance accepted';
  exception when check_violation then v_passed := v_passed + 1;
  end;

  -- 9. A group with transactions can't be hard-deleted (ledger protection).
  begin
    delete from public.groups where id = v_group;
    raise exception 'FAIL 9: group with transactions deleted';
  exception when foreign_key_violation then v_passed := v_passed + 1;
  end;

  raise exception 'SMOKE_OK: % checks passed (all changes rolled back)', v_passed;
end;
$$;
