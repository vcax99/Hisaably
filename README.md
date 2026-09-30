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
dart format lib test
flutter analyze
flutter test                      # unit + widget tests (live tests are skipped)
scripts/run_live_tests.sh         # Flutter tests against the dev backend (throwaway users)
supabase/tests/e2e/run_admin_users_e2e.sh   # admin-users Edge Function end-to-end
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
supabase/      migrations, SQL tests, Edge Functions (from Phase 2)
docs/          plan, setup guides
```
Layering: UI → Riverpod provider/controller → Repository → local (Drift) / remote (Supabase) data source. Widgets never call Supabase directly.

## Key rules
- Transactions belong to the group and have no `created_by` / `user_id` / `member_id`.
- Money is `NUMERIC(14,2)` on the server and integer paise on the client, never floating point.
- The server (RLS, RPC, Edge Functions) is authoritative for every permission and business rule; UI checks are only for user experience.
- Months are evaluated in Asia/Kolkata; future-dated transactions are rejected.

_Sections on database migrations, RLS, offline sync, notifications, testing and release are added as each phase lands._
