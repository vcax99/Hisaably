-- Hisaably — Phase 3: explicit function lockdown
-- On this project, functions created by migrations still get EXECUTE for
-- PUBLIC despite the default-privilege change in 20261001000300. That exposed
-- internal SECURITY DEFINER helpers (e.g. ensure_group_category) to anyone.
--
-- RULE FOR EVERY FUTURE MIGRATION THAT CREATES FUNCTIONS:
--   end it with the same `revoke ... from public, anon` statement below, then
--   `grant execute ... to authenticated` only for functions the app calls.
-- The Phase 3 smoke test fails if any public function is executable by
-- PUBLIC or anon.

revoke execute on all functions in schema public from public, anon;

-- Internal helpers: not callable by clients at all (they are still usable
-- inside SECURITY DEFINER RPCs, which run as the owner).
revoke execute on function
  public.raise_app_error(text, text),
  public.require_active_user(),
  public.require_super_admin(),
  public.normalize_name(text, integer, text),
  public.ensure_group_category(uuid, public.transaction_type, text),
  public.validate_transaction_fields(public.transaction_type, numeric, text, text, date),
  public.resolve_visible_groups(uuid),
  public.format_inr(numeric),
  public.ist_today()
from authenticated;
