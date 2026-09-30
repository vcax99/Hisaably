-- Hisaably — promote the FIRST Super Admin (one-time, trusted setup).
--
-- The app can never grant SUPER_ADMIN: profiles are always created as USER.
-- This script runs in the Supabase Dashboard's SQL Editor (owner privileges).
--
-- Steps:
--   1. Dashboard → Authentication → Users → "Add user" → "Create new user"
--        Email:    <username>@users.hisaably.invalid   (e.g. bikash@users.hisaably.invalid)
--        Password: <a strong password; you'll log in to the app with it>
--        [x] Auto Confirm User
--      The part before '@' becomes the app username (lowercase, 3–30 chars,
--      letters/digits, with inner '.' or '_' allowed).
--   2. Edit the two values below, then paste this whole file into
--      Dashboard → SQL Editor → Run.
--   3. Log in to the app with just the username + password.

do $$
declare
  v_username text := 'bikash';        -- ← the username from step 1
  v_name     text := 'Bikash';        -- ← display name
  v_updated  integer;
begin
  update public.profiles
     set role = 'SUPER_ADMIN',
         status = 'ACTIVE',
         name = v_name
   where username = lower(v_username);

  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'No profile with username "%". Create the auth user first (step 1).', v_username;
  end if;

  raise notice 'User "%" is now SUPER_ADMIN.', v_username;
end;
$$;

select id, username, name, role, status from public.profiles where role = 'SUPER_ADMIN';
