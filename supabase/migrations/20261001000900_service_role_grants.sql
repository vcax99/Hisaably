-- Hisaably — Phase 3: server-side (service_role) table access
-- The project's "don't auto-expose new tables" setting also withholds DML
-- from service_role. Edge Functions (admin-users now; send-push and the
-- monthly job later) use service_role, which only ever exists server-side
-- and bypasses RLS by design. Clients (anon/authenticated) are unaffected.

grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to service_role;
alter default privileges for role postgres in schema public
  grant usage, select on sequences to service_role;
