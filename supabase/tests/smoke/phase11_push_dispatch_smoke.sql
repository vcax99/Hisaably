-- Phase 11 push-dispatch smoke test. One DO block that always ends with an
-- exception, so everything (including pg_net's queued requests) is rolled
-- back and nothing is sent. Success = 'SMOKE_OK: ...'.
--
--   npx supabase db query --linked -f supabase/tests/smoke/phase11_push_dispatch_smoke.sql

do $$
declare
  u uuid := gen_random_uuid();
  v_before bigint;
  v_int integer;
  v_ids uuid[];
  v_sizes int[];
  v_passed integer := 0;
  r record;
begin
  insert into auth.users (id, email, raw_user_meta_data)
  values (u, 'p_u@users.hisaably.invalid', '{"username":"p_u"}');
  select coalesce(max(id), 0) into v_before from net.http_request_queue;

  -- 1. One statement with 1,201 rows → 3 calls of ≤500 ids.
  insert into public.notifications (recipient_id, type, title, body)
  select u, 'MONTHLY_SUMMARY', 'p' || n, 'b' from generate_series(1, 1201) n;

  select array_agg(jsonb_array_length(convert_from(q.body, 'utf8')::jsonb -> 'notification_ids') order by q.id)
    into v_sizes
  from net.http_request_queue q where q.id > v_before;
  if v_sizes is distinct from array[500, 500, 201] then
    raise exception 'FAIL 1: chunk sizes %', v_sizes;
  end if;
  v_passed := v_passed + 1;

  -- 2. Every id exactly once; all are this statement's rows.
  select array_agg(x::uuid) into v_ids
  from net.http_request_queue q,
       jsonb_array_elements_text(convert_from(q.body, 'utf8')::jsonb -> 'notification_ids') x
  where q.id > v_before;
  if cardinality(v_ids) <> 1201
     or (select count(distinct x) from unnest(v_ids) x) <> 1201
     or exists (select 1 from unnest(v_ids) x
                where not exists (select 1 from public.notifications n
                                  where n.id = x and n.recipient_id = u)) then
    raise exception 'FAIL 2: ids not exactly the inserted rows';
  end if;
  v_passed := v_passed + 1;

  -- 3. Calls go to send-push with the shared-secret header.
  for r in select url, headers from net.http_request_queue where id > v_before loop
    if r.url not like '%/functions/v1/send-push'
       or coalesce(r.headers ->> 'x-dispatch-secret', '') = '' then
      raise exception 'FAIL 3: url/header';
    end if;
  end loop;
  v_passed := v_passed + 1;

  -- 4. Single-row statements → one call each.
  select max(id) into v_before from net.http_request_queue;
  insert into public.notifications (recipient_id, type, title, body)
  values (u, 'MONTHLY_SUMMARY', 'single 1', 'b');
  insert into public.notifications (recipient_id, type, title, body)
  values (u, 'MONTHLY_SUMMARY', 'single 2', 'b');
  select count(*) into v_int from net.http_request_queue where id > v_before;
  if v_int <> 2 then raise exception 'FAIL 4: % calls', v_int; end if;
  v_passed := v_passed + 1;

  -- 5. Not configured (no URL) → the write still succeeds, nothing queued.
  delete from vault.secrets where name = 'push_dispatch_url';
  select max(id) into v_before from net.http_request_queue;
  insert into public.notifications (recipient_id, type, title, body)
  values (u, 'MONTHLY_SUMMARY', 'unconfigured', 'b');
  select count(*) into v_int from net.http_request_queue where id > v_before;
  if v_int <> 0 then raise exception 'FAIL 5: queued without URL'; end if;
  if not exists (select 1 from public.notifications where title = 'unconfigured') then
    raise exception 'FAIL 5b: write lost';
  end if;
  v_passed := v_passed + 1;

  raise exception 'SMOKE_OK: % checks passed (all changes rolled back)', v_passed;
end
$$;
