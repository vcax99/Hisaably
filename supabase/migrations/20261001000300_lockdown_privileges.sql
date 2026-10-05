-- Hisaably — Phase 2: deny-by-default privileges
-- The project's "don't auto-expose new tables" setting still leaves TRUNCATE,
-- REFERENCES and TRIGGER on new tables for anon/authenticated (TRUNCATE
-- bypasses RLS), and new functions are EXECUTE-able by anon by default.
-- Remove all of that. Phase 3 grants exactly what each role needs, table by
-- table and RPC by RPC.

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

-- Supabase's own automatic-RLS event-trigger helper doesn't need to be
-- callable via /rest/v1/rpc (event triggers don't check EXECUTE).
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke all on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end;
$$;
