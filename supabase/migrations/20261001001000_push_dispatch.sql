-- Phase 11: push dispatch.
-- After notifications are committed, pg_net calls the send-push Edge Function
-- (FCM HTTP v1). pg_net queues the request inside the transaction and sends
-- it only after COMMIT, so a rolled-back write never notifies anyone.
-- Push is best effort: a dispatch problem never fails the user's write.

create extension if not exists pg_net with schema extensions;

-- Shared secret between this trigger and the function. Generated here, so
-- it never appears in the repo; copied into the function's secrets by
-- scripts/configure_push_dispatch.sh.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'push_dispatch_secret') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'push_dispatch_secret',
      'Shared secret: notifications trigger -> send-push function'
    );
  end if;
end
$$;

-- The function URL differs per project (dev/prod), so it is stored in Vault
-- by scripts/configure_push_dispatch.sh as 'push_dispatch_url'. Until then
-- the trigger does nothing.
create function public.dispatch_push_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
  v_ids    uuid[];
  v_chunk  int := 500; -- send-push accepts up to 500 ids per call
  i        int;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'push_dispatch_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'push_dispatch_secret';
  if v_url is null or v_secret is null then
    return null;
  end if;

  select array_agg(id order by id) into v_ids from inserted;
  if v_ids is null then
    return null;
  end if;

  i := 1;
  while i <= cardinality(v_ids) loop
    perform net.http_post(
      url := v_url,
      body := jsonb_build_object('notification_ids', to_jsonb(v_ids[i : i + v_chunk - 1])),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-dispatch-secret', v_secret
      ),
      timeout_milliseconds := 10000
    );
    i := i + v_chunk;
  end loop;
  return null;
exception when others then
  raise warning 'push dispatch skipped (%)', sqlstate;
  return null;
end;
$$;

create trigger notifications_dispatch_push
  after insert on public.notifications
  referencing new table as inserted
  for each statement
  execute function public.dispatch_push_notifications();

-- Internal function: never callable by clients (see Phase 3 gotcha).
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.dispatch_push_notifications() from authenticated;
