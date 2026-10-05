# Hisaably: developer guide

Everything you need to go from a fresh clone to a running app with your own backend, plus the rules of the codebase, how to test, and how to ship builds.

- [1. What Hisaably is, technically](#1-what-hisaably-is-technically)
- [2. Tools and accounts](#2-tools-and-accounts)
- [3. Keys and secrets](#3-keys-and-secrets)
- [4. Quick start](#4-quick-start)
- [5. Set up your own Supabase backend](#5-set-up-your-own-supabase-backend)
- [6. Push notifications (Android, optional)](#6-push-notifications-android-optional)
- [7. Running the app](#7-running-the-app)
- [8. Codebase tour](#8-codebase-tour)
- [9. Rules you must follow](#9-rules-you-must-follow)
- [10. Testing](#10-testing)
- [11. Builds and releases](#11-builds-and-releases)
- [12. Dev and prod environments](#12-dev-and-prod-environments)
- [13. Troubleshooting](#13-troubleshooting)

Backend reference (tables, RPCs, Edge Functions, error codes): **[BACKEND.md](BACKEND.md)**.

---

## 1. What Hisaably is, technically

A Flutter app (Android + iOS) backed entirely by **Supabase**. There's no custom server.

| Layer | Technology |
|---|---|
| UI | Flutter, Material 3, custom dark theme |
| State | Riverpod 3 |
| Navigation | GoRouter (two bottom-nav shells: Members/Group Admins, and Super Admin) |
| Auth | Supabase Auth (username + password; no public sign-up) |
| Data | Postgres with row-level security (RLS). All writes go through RPCs (SQL functions) |
| Privileged admin | Edge Function `admin-users` (create/disable/delete users, reset passwords) |
| Offline | Drift (SQLite) cache + an outbox that syncs when the server is reachable |
| Push | Edge Function `send-push` → Firebase Cloud Messaging (Android only) |
| Scheduled jobs | `pg_cron` (monthly summaries and "New Month Started" notifications) |

**Roles**
- **Super Admin** (global): creates users and groups, assigns Group Admins, sees everything.
- **Group Admin** (per group): edits/deletes entries, manages categories, renames the group, enables or disables plain members.
- **Member** (per group): views everything in the group and adds income/expenses.

Money belongs to the group: transactions never store who created them.

---

## 2. Tools and accounts

| Tool | Version used | Needed for |
|---|---|---|
| [Flutter](https://docs.flutter.dev/get-started/install) | stable, Dart ≥ 3.13 (developed on 3.47) | everything |
| Xcode + CocoaPods | Xcode 26+, CocoaPods 1.17+ | iOS builds (macOS only) |
| Android Studio / Android SDK + Java 17 | API 36 emulator works well | Android builds |
| Node.js | 18+ | the Supabase CLI via `npx supabase …` (no global install needed) |
| Python 3 | any recent | helper scripts and E2E tests |
| Git + GitHub CLI (`gh`) | optional | PRs, triggering CI builds |

| Account | Cost | Needed for |
|---|---|---|
| [Supabase](https://supabase.com) | Free plan (2 projects) | backend: you need **your own** project to develop |
| [Firebase](https://console.firebase.google.com) | Free (Spark) | Android push only; the app works without it |
| Apple ID | Free | installing on your own iPhone (7-day signing) |
| Apple Developer Program | $99/yr, optional | TestFlight, iOS push, long-lived installs |

> **Docker is not needed.** Development runs against a free cloud Supabase project instead of a local stack.

---

## 3. Keys and secrets

The app only ever contains **public** values. Everything else stays on the server, in your password manager, or in GitHub encrypted secrets.

| Value | Secret? | Where you get it | Where it goes |
|---|---|---|---|
| Supabase project URL | No | Supabase → Project Settings → Data API | `env/dev.json` → `SUPABASE_URL` |
| Supabase publishable key (`sb_publishable_…`) | No (safe in the app; RLS protects data) | Project Settings → API Keys | `env/dev.json` → `SUPABASE_PUBLISHABLE_KEY` |
| Supabase **secret / service_role** key | **YES** | Project Settings → API Keys | **Never** in the app or repo. Edge Functions get it automatically. Scripts fetch it into memory via your CLI login (`scripts/with_dev_keys.sh`). |
| Database password | **YES** | set when you create the project | typed only when `supabase link` asks |
| Supabase access token | **YES** | created by `npx supabase login` | stored by the CLI on your machine |
| Firebase client values (project id, sender id, Android app id, Android API key) | No (client config) | Firebase → Project settings → your Android app → `google-services.json` | `env/dev.json` → `FIREBASE_*` |
| Firebase **service account** JSON | **YES** | Firebase → Project settings → Service accounts → Generate new private key | `secrets/` (git-ignored) → uploaded as the `FCM_SERVICE_ACCOUNT` function secret by `scripts/configure_push_dispatch.sh` |
| Push dispatch secret | **YES** | generated inside the database (Vault) by a migration | copied to the `PUSH_DISPATCH_SECRET` function secret by the same script; you never see it |
| Android upload keystore (`.jks`) + its passwords | **YES** | you create it once (see §11) | GitHub secrets (+ an offline backup). Never commit it. |

**`env/*.json` format** (template: [`env/example.json`](../env/example.json)):

```json
{
  "APP_ENV": "dev",
  "SUPABASE_URL": "https://<project-ref>.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_…",
  "FIREBASE_PROJECT_ID": "",
  "FIREBASE_MESSAGING_SENDER_ID": "",
  "FIREBASE_ANDROID_APP_ID": "",
  "FIREBASE_ANDROID_API_KEY": ""
}
```

`APP_ENV` is `dev` or `prod`. Leave the Firebase fields empty to run without push.

**Git-ignored on purpose:** `env/*.json` (except the example), `secrets/`, `*.jks`, `*.keystore`, `android/key.properties`. Keep it that way.

---

## 4. Quick start

```bash
git clone https://github.com/vcax99/Hisaably.git
cd Hisaably
flutter pub get
cp env/example.json env/dev.json      # then fill it in (§5)
flutter run --dart-define-from-file=env/dev.json
```

Without a filled-in `env/dev.json` the app still starts (useful for UI work), but it can't sign in.

Generated code (Drift) is committed. If you change a table in `lib/core/database/`, regenerate it:

```bash
dart run build_runner build --delete-conflicting-outputs
```

---

## 5. Set up your own Supabase backend

About 20 minutes, all on the free plan.

### 5.1 Create the project
1. [supabase.com](https://supabase.com) → **New project**. Name it e.g. `hisaably-dev`, choose a nearby region (Mumbai for India), generate a database password and store it in a password manager.
2. Leave **Data API** enabled.

### 5.2 Authentication settings (dashboard → Authentication → Sign In / Providers)
- **Email** provider: **enabled.** (Users sign in with a username; internally that's an email, see below.)
- **Allow new users to sign up:** **OFF.** Users are created only by the Super Admin through the `admin-users` Edge Function.
- **Confirm email:** **OFF.**

> ⚠️ In `supabase/config.toml`, `[auth.email] enable_signup` must stay **`true`**. On hosted projects that switch is the whole Email provider, so `false` blocks every sign-in after a `config push`. Sign-up is disabled by `[auth] enable_signup = false` instead.

### 5.3 Link the repo and apply the schema

```bash
npx supabase login                                   # opens a browser
npx supabase link --project-ref <your-project-ref>   # asks for the DB password
npx supabase db push --dry-run                       # preview the migrations
npx supabase db push --yes </dev/null                # apply them
npx supabase config push                             # auth settings from config.toml (review the diff)
```

The migrations create every table, RLS policy, RPC, trigger, the `pg_net` push dispatcher and the `pg_cron` monthly job.

### 5.4 Deploy the Edge Functions

```bash
npx supabase functions deploy admin-users --no-verify-jwt
npx supabase functions deploy send-push  --no-verify-jwt
```

Both verify their callers themselves, hence `--no-verify-jwt`. `admin-users` checks for an active Super Admin; `send-push` checks a shared secret.

Then wire the push dispatcher. This works even without Firebase; push is simply skipped:

```bash
scripts/configure_push_dispatch.sh
```

### 5.5 Create the first Super Admin (once per project)
1. Dashboard → Authentication → Users → **Add user → Create new user**:
   - Email: `<username>@users.hisaably.invalid` (e.g. `admin@users.hisaably.invalid`)
   - a strong password; tick **Auto Confirm User**
2. Dashboard → SQL Editor → paste [`supabase/bootstrap/promote_super_admin.sql`](../supabase/bootstrap/promote_super_admin.sql), set the username and display name at the top, **Run**.
3. In the app, sign in with just the **username** and the password.

From then on, create every other user, group and membership **in the app** (Users and Groups tabs).

**About usernames:** 3–30 characters, lowercase letters/digits with inner `.` or `_`. The app signs in with the synthetic email `<username>@users.hisaably.invalid`. It's never shown and never receives mail (`.invalid` is a reserved domain).

### 5.6 Fill in `env/dev.json`
Put your project URL and publishable key into `env/dev.json` (§3) and run the app.

### 5.7 Sanity checks

```bash
for f in supabase/tests/smoke/*.sql; do npx supabase db query --linked -f "$f" </dev/null 2>&1 | grep -o 'SMOKE_OK[^\\"]*'; done
npx supabase db advisors --linked
```

Each suite ends in `SMOKE_OK: N checks passed (all changes rolled back)`. The expected advisor warnings are "authenticated can execute SECURITY DEFINER function" for app RPCs (each checks permissions itself) and Pro-only auth features.

---

## 6. Push notifications (Android, optional)

Without this, everything works and notifications appear in the app's bell; there's just no system push.

1. Firebase console → **Add project** (Analytics not needed) → **Add app → Android**, package name **`com.bikash.hisaably`**.
2. Download `google-services.json`. Copy its public values into `env/dev.json`:
   - `FIREBASE_PROJECT_ID` = `project_info.project_id`
   - `FIREBASE_MESSAGING_SENDER_ID` = `project_info.project_number`
   - `FIREBASE_ANDROID_APP_ID` = `client[0].client_info.mobilesdk_app_id`
   - `FIREBASE_ANDROID_API_KEY` = `client[0].api_key[0].current_key`

   The app calls `Firebase.initializeApp(options: …)` from these values, so no Gradle plugin and no committed `google-services.json` is needed.
3. Firebase → Project settings → **Service accounts → Generate new private key**. Save it as `secrets/firebase-service-account.json` (git-ignored) and run:
   ```bash
   scripts/configure_push_dispatch.sh secrets/firebase-service-account.json
   ```

How it works: an RPC inserts notification rows (never for the person who acted) → an `AFTER INSERT` trigger calls `send-push` via `pg_net` **after commit** → FCM HTTP v1. Dead tokens are deactivated automatically.

iOS push needs a paid Apple Developer account (APNs). Without one, iPhones get in-app notifications only.

---

## 7. Running the app

```bash
flutter devices
flutter run -d <device-id> --dart-define-from-file=env/dev.json
```

- **iOS Simulator / Android emulator:** just works.
- **Your own iPhone (free Apple ID):** open `ios/Runner.xcworkspace` once, set *Signing & Capabilities → Team* to your personal team, connect the phone, enable Developer Mode, run `flutter run -d <udid> --release --dart-define-from-file=env/dev.json`, then trust the developer in Settings → General → VPN & Device Management. Free signing expires after 7 days; re-running installs over the app and keeps its data.
- **Debug auto sign-in** (debug builds only): add `--dart-define=DEV_LOGIN_USER=<username> --dart-define=DEV_LOGIN_PASS=<password>` to sign in once on launch.

---

## 8. Codebase tour

```
lib/
  main.dart, app.dart          bootstrapping, Supabase client, lifecycle hooks
  core/
    config/                    env (dart-defines), app version
    database/                  Drift tables (local transactions, outbox, cache)
    errors/                    AppFailure + error_mapper (server codes → friendly messages)
    network/                   NetworkStatus, OfflineAwareClient, reachability check
    push/                      FCM registration and tap handling (Android)
    sync/                      outbox processor, sync engine, background sync, offline banner
    theme/                     colour tokens, spacing, fonts, ThemeData
    utils/                     Money (integer paise), IstDate (Asia/Kolkata dates)
    widgets/                   shared widgets: logo, wave background, dialogs…
  features/<feature>/
    domain/                    plain models
    data/                      repositories (Supabase + local)
    application/               Riverpod providers / controllers
    presentation/              screens and widgets
  routing/                     GoRouter config, shells, session redirect
supabase/
  migrations/                  schema, RLS, RPCs, cron, push dispatch (applied in order)
  functions/                   admin-users, send-push (Deno/TypeScript)
  bootstrap/                   one-time Super Admin promotion script
  tests/                       SQL smoke suites, perf benchmark, admin-users E2E
integration_test/              on-device UI flows and perf test
test/                          unit + widget tests (test/live talks to your dev backend)
tool/readme_screenshots/       captures the README screenshots (see §10)
scripts/                       helper scripts (checks, live tests, push config…)
```

**Layering:** UI → Riverpod provider → repository → local (Drift) / remote (Supabase). Widgets never call Supabase directly.

**Offline-first writes:** adding an entry generates a UUID, saves it to SQLite with an outbox record and shows it as *Pending*. The sync engine sends it when the server is reachable (startup, resume, network regained, "Sync now", backoff timer while open). `upsert_transaction` is idempotent on that UUID, so retries never duplicate. Editing or deleting a synced entry needs a connection.

---

## 9. Rules you must follow

**Data and security**
- Transactions carry **no user reference** (`created_by`, `user_id`, …), including in Drift tables and outbox payloads.
- Clients have **no INSERT/UPDATE/DELETE** grants. Every write goes through an RPC or the `admin-users` function, and every permission is checked **on the server**. UI hiding is cosmetic.
- **New SQL functions:** end the migration with
  ```sql
  revoke execute on all functions in schema public from public, anon;
  grant execute on function public.<your_rpc>(...) to authenticated;   -- app-facing RPCs only
  ```
  On Supabase, new functions otherwise get `EXECUTE` for `PUBLIC`. Add internal helpers to the exposure check in `phase3_security_smoke.sql`.
- Never put a secret/service-role key, DB password, service account or keystore in the app or the repo. Never log tokens.

**Money and dates**
- Money is `NUMERIC(14,2)` on the server and **integer paise** in Dart (`Money`). Never `double`.
- Months and "today" are **Asia/Kolkata** (`IstDate`). Future-dated entries are rejected on both client and server.
- Parse Postgres `DATE` with **`IstDate.parseDate`**, never `DateTime.parse` (that gives local midnight and breaks "today").

**Supabase client gotchas**
- Read tables with **`client.rest.from('table')`**, not `client.from(...)`. The latter ignores `postgrestOptions` (retries off), which makes offline screens hang for seconds. A test enforces this.
- postgrest-dart's `.order(col)` defaults to **descending**: always pass `ascending:` explicitly.

**UI**
- Colours only from `AppColors` (in `lib/core/theme/`); no `Color(0x…)` elsewhere. Spacing from `AppSpacing`.
- New routes must be built with `_route(...)` / `_page(...)` in `app_router.dart`, which wraps the page in the animated background.
- Every screen needs loading, empty, error, offline and retry states. Never show raw database errors; map them through `error_mapper.dart`.
- Bottom-nav items have keys `nav-<Label>`; tests rely on them.

**Style:** `dart format`, `flutter analyze` clean, tests for new behaviour.

---

## 10. Testing

| What | Command | Notes |
|---|---|---|
| Format + analyze | `dart format lib test integration_test test_driver` · `flutter analyze` | must be clean |
| Unit + widget | `flutter test` | no backend needed (fakes in `test/helpers/`) |
| Live backend tests | `scripts/run_live_tests.sh [file…]` | run against your **linked dev** project; create and delete their own throwaway users. Pass single files to avoid Auth rate limits. |
| SQL smoke suites | `npx supabase db query --linked -f supabase/tests/smoke/<suite>.sql` | always rolled back; success = `SMOKE_OK` |
| admin-users E2E | `supabase/tests/e2e/run_admin_users_e2e.sh` | creates/deletes throwaway users |
| Everything above | `scripts/run_all_checks.sh` | |
| On-device UI flows | `QA_ADMIN_PASSWORD=… QA_MEMBER_PASSWORD=… scripts/run_device_flows.sh <device-id>` | needs users `qa_admin` (Super Admin) and `qa_member` (Group Admin of a group named **QA Roomies**) in your dev project |
| Frame timings | `QA_MEMBER_PASSWORD=… scripts/run_perf.sh <android-device-id>` | profile mode → `build/perf/` |
| README screenshots | `DEMO_ADMIN_PASSWORD=… DEMO_MEMBER_PASSWORD=… DEMO_GROUP_ID=<uuid> scripts/capture_readme_screens.sh <ios-simulator-id>` | signs in as `aarav` (Group Admin) and `meera` (member) of a demo group in dev → `build/readme_screens/`; README images live in `.github/readme/` |

Scripts that need the service key (`with_dev_keys.sh`) fetch it with your CLI login and keep it in memory only. Never point tests at production.

---

## 11. Builds and releases

### Android APK in the cloud (GitHub Actions)
The **Actions** tab has two workflows, both built by the shared `.github/workflows/_android-apk.yml`:

| Workflow | Backend | Settings secret | Output |
|---|---|---|---|
| **Android dev APK** | dev | `APP_ENV_JSON_DEV` | `Hisaably-dev.apk` |
| **Android prod APK** | prod | `APP_ENV_JSON` | `Hisaably-prod.apk` |

Each run refuses settings whose `APP_ENV` doesn't match, signs with the upload key and verifies the signature. Run one from Actions → *workflow* → **Run workflow** (or `gh workflow run android-prod-apk.yml --ref Dev`), then download the APK from the run's **Artifacts**.

Repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `APP_ENV_JSON` | the **prod** env JSON (one line) |
| `APP_ENV_JSON_DEV` | the **dev** env JSON |
| `ANDROID_KEYSTORE_BASE64` | `base64 -i upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias (e.g. `upload`) |
| `ANDROID_KEY_PASSWORD` | key password |

**Creating an upload key** (once; keep it forever, because every update must be signed with the same key):

```bash
keytool -genkeypair -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias upload -dname "CN=<name>, O=Hisaably, C=IN"
```

Store the `.jks` and its passwords in a safe offline backup and in the GitHub secrets above. Losing it means users must uninstall to get updates.

### Local builds

```bash
flutter build apk --release --dart-define-from-file=env/dev.json
```

Release signing reads `android/key.properties` (git-ignored):

```
storeFile=/absolute/path/upload-keystore.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

Without it, release builds are **debug-signed**. Those can't update an installed copy that was signed with the upload key; the app must be uninstalled first.

iOS:

```bash
flutter build ios --release --dart-define-from-file=env/prod.json
xcrun devicectl device install app --device <coredevice-id> build/ios/iphoneos/Runner.app
```

### Versioning
`version:` in `pubspec.yaml` (e.g. `1.1.0+2`; the part after `+` must increase for Android updates). The version is shown on the start-up screen and in Account.

---

## 12. Dev and prod environments

- Use **two Supabase projects**: dev (testing, throwaway users) and prod (real users). Free allows two.
- Keep the repo folder **linked to dev**. Every script uses the linked project. To change prod, copy `supabase/` to a scratch folder, link that copy to prod and run `db push`, `functions deploy` and `configure_push_dispatch.sh` from there.
- Apply migrations to dev first, run the checks, then to prod.
- Builds choose the backend only through `--dart-define-from-file` (`env/dev.json` / `env/prod.json`). One phone can't hold both builds (same app id); switching wipes the local offline data so nothing crosses over.

---

## 13. Troubleshooting

| Symptom | Fix |
|---|---|
| Sign-in shows "Something went wrong" and Auth says *Email logins are disabled* | Enable the Email provider (§5.2); keep `[auth.email] enable_signup = true` in `config.toml` |
| Everything fails after a week of no use | Free projects pause after ~7 days without requests. Dashboard → **Restore** (no data loss). |
| `supabase projects api-keys` shows a short `sb_secret_…` | It's masked; add `--reveal`. Send secret keys only in the `apikey` header, never as a Bearer token. |
| Live tests fail with HTTP 429 | Supabase Auth rate limit: run fewer test files at a time |
| Offline screens take seconds to show | Something used `client.from(...)` instead of `client.rest.from(...)` |
| A date shows as yesterday / "today" is wrong | A `DATE` was parsed with `DateTime.parse`; use `IstDate.parseDate` |
| Lists come out reversed | `.order()` without `ascending:` (defaults to descending) |
| CI run stays *Queued* and is cancelled after 15 min with 0 steps | GitHub Actions incident; check [githubstatus.com](https://www.githubstatus.com) and re-run |
| `pumpAndSettle` never finishes in a test | Ambient animations: set `ambientMotionEnabled = false` (already done in `test/flutter_test_config.dart`) |
| iOS app won't open after a week | Free signing expired: build and install again (installing over keeps data) |
