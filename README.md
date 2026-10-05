# Hisaably

A collective money tracker for Android and iOS. Money belongs to the **group**, not to individual members: everyone in a group records income and expenses into one shared ledger, with monthly balances that carry forward.

**Author:** Bikash

**Stack:** Flutter · Riverpod · GoRouter · Supabase (Auth, Postgres + RLS, RPC, Edge Functions) · Drift/SQLite (offline) · FCM/APNs

- Implementation plan and decisions: [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)
- Supabase setup (free tier): [docs/SUPABASE_SETUP.md](docs/SUPABASE_SETUP.md)
- Backend reference (tables, RPCs, Edge Function, error codes, tests): [docs/BACKEND.md](docs/BACKEND.md)

## Prerequisites
- Flutter (stable), Xcode + CocoaPods (iOS), Android SDK + Java 17 (Android)
- Supabase CLI: `brew install supabase/tap/supabase`, or run it without installing via `npx supabase …`

## Configuration
Only **public** client values ship in the app. They're passed at build time:

```bash
cp env/example.json env/dev.json     # env/*.json is git-ignored (except example.json)
# fill in SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY
```

Never put the Supabase secret/service-role key, database password, Firebase service account or signing keys in `env/*.json` or anywhere in this repository.

## Run
```bash
flutter pub get
flutter run --dart-define-from-file=env/dev.json
```
If you run without the env file, the app starts but doesn't connect to Supabase (useful for UI-only work).

## Checks
```bash
scripts/run_all_checks.sh         # everything below except device flows
dart format lib test
flutter analyze
flutter test                      # unit + widget tests (live tests are skipped)
scripts/run_live_tests.sh         # Flutter tests against the dev backend (throwaway users)
supabase/tests/e2e/run_admin_users_e2e.sh   # admin-users Edge Function end-to-end
npx supabase db query --linked -f supabase/tests/smoke/<suite>.sql   # SQL suites (always rolled back)
QA_ADMIN_PASSWORD=… QA_MEMBER_PASSWORD=… scripts/run_device_flows.sh <device-id>   # UI flows on a simulator/emulator
QA_MEMBER_PASSWORD=… scripts/run_perf.sh <android-device-id>   # profile-mode frame timings → build/perf/
```
Live runners fetch the dev project's keys with your Supabase CLI login and keep them in memory only (`scripts/with_dev_keys.sh`).

## Signing in
Users sign in with a **username** and password created by the Super Admin (there is no public sign-up and no email). The first Super Admin is bootstrapped once, as described in docs/SUPABASE_SETUP.md §7.

## Project structure
```
lib/
  core/        config, constants, theme (color tokens), errors, utils, shared widgets
  features/    auth, dashboard, expenses, income, groups, users, notifications, settings, transactions
  routing/     GoRouter config, bottom-nav shell, route paths
supabase/      migrations, SQL smoke/perf tests, Edge Functions (admin-users, send-push)
docs/          plan, setup guides
```
Layering: UI → Riverpod provider/controller → Repository → local (Drift) / remote (Supabase) data source. Widgets never call Supabase directly.

## Key rules
- Transactions belong to the group and have no `created_by` / `user_id` / `member_id`.
- Money is `NUMERIC(14,2)` on the server and integer paise on the client, never floating point.
- The server (RLS, RPC, Edge Functions) is authoritative for every permission and business rule; UI checks are only for user experience.
- Months are evaluated in Asia/Kolkata; future-dated transactions are rejected.

## Offline and sync
- Adding income/expense works fully offline: the entry is saved in SQLite (Drift) with an outbox record and shows as **Pending**; editing or deleting a synced entry needs a connection.
- The sync engine (`lib/core/sync/`) sends the outbox when the server is actually reachable (health check, not just "has Wi-Fi") on: app start, resume, network regained, "Sync now", and, while the app is open, at the next backoff time after a server error. There is no polling.
- Sends are idempotent (client-generated UUIDs), so retries never duplicate. Rejected entries show **Not synced** with the reason, plus Retry/Discard.
- Background sync (Android WorkManager / iOS BGTaskScheduler) is best effort only. It never refreshes auth tokens.

## Notifications
- The server creates notification rows after a committed write, for the other active members of the group (never the actor).
- A trigger asks the `send-push` Edge Function (FCM HTTP v1) to deliver them, via pg_net after commit. Configure with `scripts/configure_push_dispatch.sh [firebase-service-account.json]`; without the service account, in-app notifications still work.
- Monthly processing (`pg_cron`, 00:05 IST on the 1st) refreshes `monthly_summaries` and sends one "New Month Started" notification per member. It's idempotent; re-run a missed month with `select public.run_monthly_processing('YYYY-MM-01');`.

## Release builds
```bash
flutter build appbundle --release --dart-define-from-file=env/prod.json
flutter build ipa --release --dart-define-from-file=env/prod.json      # needs a paid Apple Developer team
```
Android release signing uses `android/key.properties` + an upload keystore (both git-ignored); until that is set up, release builds are debug-signed.
