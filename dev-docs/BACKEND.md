# Hisaably: backend reference (Supabase)

← Back to the [developer guide](README.md)

Everything the app talks to on the server: tables it may read, RPCs it calls, the admin Edge Function, error codes, and how to test.

## Security model
- **Reads:** signed-in users (`authenticated`) have `SELECT` on the tables below, filtered by RLS. `anon` has nothing.
- **Writes:** **only** through the RPCs / Edge Function below. Clients have no `INSERT/UPDATE/DELETE` on any table, so nobody can change roles, statuses or other people's data directly.
- Every call re-checks, from the database (not from the JWT):
  - the caller's profile is ACTIVE;
  - their membership is ACTIVE;
  - the group is ACTIVE.

  Disabling someone takes effect on their very next request.
- The Super Admin (ACTIVE) can read everything, including disabled groups.
- Internal helpers can't be called by clients. A test asserts that no function is executable by `PUBLIC`/`anon`.

| Table | Who can read (RLS) |
|---|---|
| `profiles` | own row (even if disabled), Super Admin: all, members: people who share an active group |
| `groups`, `group_members`, `group_categories`, `transactions`, `monthly_summaries` | Super Admin, or active members of that active group |
| `notification_devices` | own devices |
| `notifications` | own notifications (active users only) |
| `transaction_history` | nobody directly. Read through `get_transaction_history()` |

## RPCs (`supabase.rpc(name, params)`)

| Operation | RPC / function | Who |
|---|---|---|
| — (routing) | `get_my_context()` → `{profile, memberships[]}` | any signed-in user (works when disabled) |
| listUsers / getUser | `select` on `profiles` | Super Admin |
| createUser, enableUser, disableUser, deleteUser, (reset password) | Edge Function `admin-users` | Super Admin |
| (rename user) | `update_user_name(p_user_id, p_name)` | Super Admin |
| listGroups / getGroup | `select` on `groups` | per RLS |
| createGroup | `create_group(p_name)` | Super Admin |
| renameGroup | `rename_group(p_group_id, p_name)` | Super Admin, Group Admin of that group |
| disableGroup | `set_group_status(p_group_id, p_status)` | Super Admin |
| listMembers | `select` on `group_members` (+ `profiles`) | per RLS |
| addMember | `add_group_member(p_group_id, p_user_id, p_group_role='MEMBER')` | **Super Admin only** |
| removeMember | `remove_group_member(p_group_id, p_user_id)` | **Super Admin only** (Group Admins can only enable/disable) |
| enableMember / disableMember | `set_group_member_status(p_group_id, p_user_id, p_status)` | Super Admin; Group Admin for plain members other than themselves |
| assignGroupAdmin / removeGroupAdmin | `set_group_member_role(p_group_id, p_user_id, p_group_role)` | Super Admin |
| addTransaction, syncPendingTransactions | `upsert_transaction(p_id, p_group_id, p_type, p_amount, p_category, p_description, p_transaction_date)` → `{created, transaction}` | active members, Super Admin |
| updateTransaction | `update_transaction(p_id, p_type, p_amount, p_category, p_description, p_transaction_date, p_expected_version?)` | Group Admin of that group, Super Admin, or an active member who added that entry |
| deleteTransaction | `delete_transaction(p_id, p_expected_version?)`: **hard delete**, idempotent | same as updateTransaction |
| (deleted lookup) | `get_deleted_transaction(p_id)` → `{type}` if it was deleted and the caller can see its group, else null | members of that group |
| listTransactions | `list_transactions(p_group_id?, p_type?, p_from?, p_to?, p_category?, p_min_amount?, p_max_amount?, p_cursor_date?, p_cursor_created_at?, p_cursor_id?, p_limit=30)` | per group access |
| getTransaction | `select` on `transactions` | per RLS |
| (categories) | `select` on `group_categories` (`is_active = true` for pickers); `rename_group_category(p_category_id, p_name)`, `delete_group_category(p_category_id)` | read: members; edit: Group Admin, Super Admin |
| getGroupDashboard / getSuperAdminDashboard | `get_dashboard(p_group_id?, p_month?, p_recent_limit=5)`; `p_group_id = null` = all groups the caller can see ("All Groups") | per group access |
| (admin counts) | `get_admin_overview()` | Super Admin |
| getMonthlySummary | `get_monthly_balances(p_group_id?, p_from_month, p_to_month)` | per group access |
| getExpenseBreakdown / getIncomeSummary | `get_category_breakdown(p_group_id?, p_type, p_from, p_to)` | per group access |
| registerDevice / unregisterDevice | `register_device(p_token, p_platform)`, `unregister_device(p_token)` | own |
| getNotifications | `select` on `notifications` order by `created_at desc` | own |
| markNotificationRead | `mark_notification_read(p_notification_id)`, `mark_all_notifications_read()` | own |
| (delete notifications) | `delete_all_notifications()` → count deleted | own |
| (auto-delete setting) | `get_notification_settings()` → `{retention_days}`; `set_notification_retention(p_days)` with 7, 15 or null (never) | own |
| (entry history) | `get_transaction_history(p_transaction_id)` → `{created: {name, at} \| null, updated: {name, at} \| null, can_edit}` | anyone who can see the entry |

**Behaviour notes**
- `upsert_transaction` is **idempotent** on the client-generated UUID. A retry returns `created: false` with the stored row, and never duplicates or re-notifies.
- Categories: an unknown category name ("Other" → typed name) is added to that group's list automatically. Names match case-insensitively and the stored name is canonical ("food" → "Food"). Renaming updates past transactions too. Deleting hides the category but past transactions keep the text.
- **Money:** send `p_amount` as a JSON number or string with at most 2 decimals. Returned amounts are NUMERIC; parse them with `Money.fromNumeric`, never via `double`.
- **Balances** are always computed from `transactions`, so backdated entries, edits and deletes are reflected immediately. `monthly_summaries` is only a cache for the monthly job.
- **Pagination:** order is `transaction_date desc, created_at desc, id desc`. For the next page, pass the last row's three values as the cursor.

## Edge Function `admin-users`
`POST /functions/v1/admin-users` with the user's access token (`supabase.functions.invoke('admin-users', body: {...})`).

| action | body | result |
|---|---|---|
| `create_user` | `name`, `username`, `password` | `{ok, user}` |
| `reset_password` | `user_id`, `password` | `{ok}` |
| `disable_user` / `enable_user` | `user_id` | `{ok}` (also bans/unbans in Auth) |
| `delete_user` | `user_id` | `{ok}` |

Rules:
- Usernames: 3–30 characters, lowercase letters and digits, with inner `.` or `_` allowed. Unique.
- Passwords: 8–72 characters.
- You can't disable or delete yourself.

Errors are returned as `{error: {code, message}}` with an HTTP status.

## Error codes
App errors from RPCs come back as Postgres errors with the code in **`hint`** (`PostgrestException.hint`). The Edge Function returns `error.code`.

`NOT_AUTHENTICATED`, `ACCOUNT_DISABLED`, `FORBIDDEN`, `NOT_FOUND`, `VALIDATION` (message is user-safe), `FUTURE_DATE`, `GROUP_DISABLED`, `USER_DISABLED`, `ALREADY_MEMBER`, `GROUP_MEMBER_LIMIT`, `CATEGORY_EXISTS`, `CONFLICT` (stale `expected_version`), `ID_CONFLICT`, `USERNAME_TAKEN`, `UNEXPECTED`.

## Edge Function `send-push`
Called only by the database (`pg_net`, after commit) with the header `x-dispatch-secret`; it rejects anything else with 401.

- Loads the given notification ids and the recipients' active Android devices, then sends FCM HTTP v1 messages (notification + data payload).
- Tokens FCM reports as unregistered are deactivated.
- Without the `FCM_SERVICE_ACCOUNT` secret it returns `{skipped: "push not configured"}`, so in-app notifications still work.
- Configure with `scripts/configure_push_dispatch.sh [service-account.json]`.

## Entry history ("Added by" / "Edited by")
Transactions themselves never store a person: the group owns the money. Who did what is kept in a separate table, `transaction_history` (`transaction_id`, `action` CREATED/UPDATED/DELETED, `actor_id`, `created_at`), written by an `AFTER INSERT OR UPDATE` trigger on `transactions` from the caller's `auth.uid()`.

- Only changes made by a signed-in user are recorded (not SQL scripts or jobs).
- An update counts as an edit only when type, amount, category, description or date actually changed. Renaming a category, which rewrites past entries, is not recorded (`rename_group_category` sets a transaction-local flag).
- **Who may edit/delete** (`can_edit_transaction`): the group's Group Admin, the Super Admin, or an active member whose `CREATED` row it is. Entries with no recorded author stay admin-only. The app shows Edit/Delete from `can_edit`.
- `actor_id` becomes null when the user is deleted; the app shows "Deleted user". Entries from before history existed have no CREATED row; the app shows "Not recorded".

## Notification cleanup
- `notifications.read_at` is set by a trigger when `is_read` turns true.
- `profiles.notification_retention_days` (7, 15 or null = never; default 7).
- `pg_cron` job `hisaably-daily-cleanup` runs daily at 21:30 UTC (03:00 IST): `purge_read_notifications()` deletes read notifications whose `read_at` is older than their recipient's retention (unread ones are never auto-deleted), and `purge_deleted_transactions()` drops tombstones older than 90 days.

## Deleting entries (hard delete)
`delete_transaction` removes the row from `transactions`. Its `transaction_history` rows cascade, and notifications keep their text with `transaction_id` set to null (the app then says "This expense has been deleted").

A tombstone in `deleted_transactions` (`id`, `group_id`, `type`, `deleted_at`: no amount, description or person) is kept for 90 days:
- `upsert_transaction` refuses a deleted id with `DELETED`, so a late re-send from a phone's offline queue can't bring the entry back. The app then drops it quietly.
- A second `delete_transaction` of the same id is a no-op.
- `get_deleted_transaction` lets an old push notification tap say "has been deleted".

`transactions.deleted_at` still exists but is always null (constraint `transactions_no_soft_delete`).

## Monthly processing
`pg_cron` job `hisaably-monthly` runs daily at 18:35 UTC (00:05 IST) and acts only on the 1st (IST): it upserts last month's `monthly_summaries` and sends one "New Month Started" notification per active member, deduplicated by `dedupe_key`. To re-run a missed month: `select public.run_monthly_processing('YYYY-MM-01');`

## Login
Users type a **username**. The app signs in with email `<username>@users.hisaably.invalid` (lowercased). This synthetic email is never shown and never receives mail.

## Migrations
`supabase/migrations/` (applied in order):

| File | Purpose |
|---|---|
| `…0100_core_schema` | enums, tables, constraints, indexes |
| `…0200_core_triggers` | profile on signup, 10-member limit, default categories |
| `…0300_lockdown_privileges` | revoke client privileges |
| `…0400_security_rls` | helpers, read grants, RLS |
| `…0500_rpc_groups_members` | context/group/member RPCs |
| `…0600_rpc_transactions` | transaction/category RPCs |
| `…0700_rpc_dashboard_notifications` | reporting and notification RPCs |
| `…0800_function_privileges` | explicit function lockdown |
| `…0900_service_role_grants` | server-side table access |
| `…1000_push_dispatch` | `pg_net` trigger → `send-push` (secret in Vault) |
| `…1100_monthly_processing` | `run_monthly_processing()` + `pg_cron` job `hisaably-monthly` |
| `…1200_list_keyset_index` | partial index for keyset pagination |
| `…1300_list_transactions_fast_path` | single-group fast path for `list_transactions` |
| `…1400_group_balances` | `get_group_balances(p_month)` for the "By group" card |
| `…1500_entry_history_notification_cleanup` | entry history, notification `read_at`, retention setting, delete-all, daily cleanup job |
| `…1600_members_edit_own_entries` | members may edit/delete entries they added |
| `…1700_hard_delete_entries` | hard delete + 90-day tombstones, purge of old soft-deleted rows, `hisaably-daily-cleanup` job |

**Rule for new migrations that create functions:** end with
```sql
revoke execute on all functions in schema public from public, anon;
grant execute on function public.<new_rpc>(...) to authenticated;   -- only app-facing RPCs
```
(On this project, default privileges do *not* stop `PUBLIC` from getting EXECUTE on new functions.)

```bash
npx supabase db push --dry-run            # preview
npx supabase db push --yes </dev/null     # apply to linked dev project
npx supabase functions deploy admin-users --no-verify-jwt
npx supabase functions deploy send-push --no-verify-jwt
```

## Tests
```bash
# SQL (rolls back everything; success = "SMOKE_OK")
npx supabase db query --linked -f supabase/tests/smoke/phase2_schema_smoke.sql
npx supabase db query --linked -f supabase/tests/smoke/phase3_security_smoke.sql
npx supabase db query --linked -f supabase/tests/smoke/phase11_push_dispatch_smoke.sql
npx supabase db query --linked -f supabase/tests/smoke/phase12_monthly_smoke.sql
npx supabase db query --linked -f supabase/tests/smoke/phase16_history_notifications_smoke.sql
# Edge Function end-to-end (creates + deletes throwaway users)
supabase/tests/e2e/run_admin_users_e2e.sh
# Linter
npx supabase db advisors --linked
```
Expected advisor warnings: "authenticated can execute SECURITY DEFINER function" for each app RPC listed above. This is by design: each RPC checks permissions itself. "Leaked password protection" is a Pro-plan feature.
