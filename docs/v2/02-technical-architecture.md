# Walkathon v2: Technical Architecture

Audience: developers. Builds on the existing conventions: Riverpod 3, go_router, repository classes returning `CustomError` through `handleException`, pages under `lib/pages/`, theme under `lib/theme/`.

## 1. Folder structure (additive)

```
lib/
  l10n/                      app_en.arb, app_ta.arb, app_hi.arb
  features/                  # new code lives here, one folder per feature
    activity/   (data/ domain/ presentation/)
    health/     health_source.dart, android_health_source.dart, ios_health_source.dart, sensor_source.dart
    friends/  groups/  events/  chat/  gamification/  profile/  ads/  admin/
  core/
    time/       local_day.dart          # timezone-safe date keys
    sync/       step_sync_service.dart  # queue + retry
    cache/      local_cache.dart
    push/       push_service.dart
supabase/
  migrations/   0001_… .sql             # incremental, versioned
  functions/    delete-account/ export-report/ send-push/ moderate-photo/
  ops/          reset_launch_data.sql  verify_reset.sql
```

Existing `lib/pages/*` stays; new screens go in `features/*/presentation`. Renames to schedule once, in their own commit: `firebase_constants.dart` → `supabase_client.dart`, `FirebaseErrorPage` → `ConnectionErrorPage`.

## 2. State management and layering

Riverpod 3 `Notifier`/`AsyncNotifier` per feature. **UI → provider → repository → Supabase/health SDK.** Repositories are the only code that touches Supabase or platform plugins, so they're mockable in tests. Errors map through the existing `handleException`; new messages are added there with tests. Repositories return domain models, not raw maps (the current leaderboard code returns `Map<String,dynamic>`, which we retire).

## 3. Step tracking and sync (Phase 2: built, not yet run on a device)

**Principle:** the phone never "counts" steps itself. It **reads** platform totals and uploads windows. The existing per-event `count + 1` logic is deleted.

| Platform | Source order | Notes |
|---|---|---|
| Android | 1) Health Connect (steps, distance, active energy, floors, via the `health` package). 2) Fallback: hardware step counter (cumulative since boot). | Health Connect only has data if some app writes it (Google Fit, Samsung Health, a wearable). The fallback covers phone-only users. |
| iOS | HealthKit (and Core Motion pedometer history for the past 7 days). | iOS keeps history, so no background counting is needed. |

**Fallback delta logic (Android):** store `(boot_id, counter, timestamp)`. On each read, compute `delta = counter − last_counter`; if the counter went down (reboot), treat the new value as the delta since boot. Attribute deltas to the local day they happened in; if a gap spans midnight, split by time proportionally and mark the day `estimated`.

**Background collection:** `workmanager` periodic task (about 15 min, OS-controlled) on Android; HealthKit background delivery plus app-open sync on iOS. No GPS and no foreground service. Every sync builds windows, hashes them (`record_hash`), appends to a local queue, and calls `ingest_steps`. Failures stay queued and retry with exponential backoff.

**Calories:** `kcal = steps × stride-based factor` using height/weight when provided, otherwise population defaults. Prefer the platform's active-energy value when available. Distance: platform value, else `steps × (0.415 × height)`.

**Risks to spike in Phase 2 (before committing):** `health` plugin versions vs our Gradle pins (AGP 8.9.1 / Kotlin 2.1.0, `permission_handler_android` pinned to 13.0.1); Health Connect `minSdk` and the background-read permission; Play Console Health Connect declaration; iOS Info.plist strings and HealthKit entitlement (both currently missing).

## 4. Timezone-safe aggregation

- Clients compute the **local date** with the device's own calendar rules (DST-safe, via the `DateTime` constructor) and send `(local_date, tz_offset_min)`. An offset is used instead of a zone name because abbreviations like `IST` are ambiguous in Postgres and Dart has no IANA lookup without another plugin. The server uses the offset only to check that "today" is plausible.
- Daily/weekly/event totals are keyed by **local date**, so travelers don't lose or double a day. Event inclusion is `local_date BETWEEN starts_on AND ends_on` (each user's own calendar day), documented in the Event editor.

## 5. Leaderboards at 15,000 members

- No client-side aggregation.
- `ingest_steps` updates `period_totals` incrementally (`day`, `week`, `event:<id>`) using the delta from the previous `step_days` value.
- `group_board` = `group_members ⋈ period_totals` filtered by `(period, period_key)` with an index on `(period, period_key, steps DESC, user_id)`; returns top N + own rank (`count(*) WHERE steps > mine`). Paginated by rank.
- Mystery Mode is applied **in the SQL function** (steps nulled for today's key), so the client can never receive hidden counts.
- "Automatic update": clients refresh on open and every 60 s while visible, and via a lightweight Realtime "board_version" ping. Push is not used for rank changes.
- Daily and weekly "reset" is not a job: a new local date/week yields a new `period_key`. Nothing is deleted, history stays.
- Load test target before launch: 15,000-member group, 500 ingests/s; board query p95 < 300 ms.

## 6. Caching

`shared_preferences` (moved to runtime dependencies) for small state; a local SQLite file (`drift` or `sqflite`; decide in Phase 2) for the step queue and recent days. Cache is keyed by user id and cleared on sign-out, on account deletion, and when `app_config.reset_epoch` changes.

## 7. Push notifications

FCM (Android directly, iOS via an APNs key). Only `firebase_core` and `firebase_messaging` are added, not Firebase Auth or Firestore. Tokens go in `device_tokens`; `send_push` Edge Function fans out with per-category opt-out, locale-aware text, and silent deletion of invalid tokens. Alternative: OneSignal (less setup, more third-party data sharing). Recommended: FCM.

## 8. Authentication and member management

- **Email and password only.** Public sign-up is **disabled** in Supabase (Authentication → Sign In / Providers → turn off "Allow new users to sign up"). The admin API still creates users, which is how members are added. With no third-party login offered, App Store guideline 4.8 (Sign in with Apple) does not apply.
- **Adding a member (built):** Super Admin enters an email and name in the app → `admin-members` Edge Function verifies the caller is a Super Admin in the database → creates the user with a random **temporary password** (shown once, never stored) → the admin shares it by WhatsApp or SMS. This needs **no email delivery and no domain**, so it works today. Invite-by-email can be added later once custom SMTP exists (Supabase's built-in email is heavily rate-limited).
- **First login (built):** the `must_change_password` flag forces a new password and the consent screen before anything else is reachable. The signup trigger creates the `self` profile; the app lets the user add spouse, children and other (max 6).
- **Bootstrap:** the very first Super Admin account is created in the dashboard (Authentication → Users → Add user, auto-confirm), then `select ops.seed_super_admin('<email>')`. A seeded email is promoted only once it is verified.
- Invite links need the deep-link setup (custom scheme now; https domain later).
- **Multiple profiles on one account:** the app stores an *active profile* per device. `ingest_steps` takes a `profile_id`, checks it belongs to `auth.uid()`, and rejects a second profile from the same device on the same local day.

## 9. Moderation

Defined in the spec (section 7). Implementation: RLS limits chat to current members; `send_message` rate-limits (e.g. 20/min), strips or validates URLs for GIF kind, and checks blocks; photos upload to a private bucket via signed upload URLs, max 2 MB, thumbnail generated client-side; reports go to `message_reports`, visible to group admins and Super Admins.

## 10. Testing strategy

- **Unit:** time/local-day, delta logic, calorie/distance, streak and rest-day rules, goal achievements, period keys, `ingest_steps` plausibility (as SQL tests with pgTAP), repository error mapping.
- **Widget:** auth flows, permission rationale, group creation, board states (loading/empty/error/Mystery), settings toggles. Extend the existing `ui_smoke_test.dart` approach (sizes × themes × text scale).
- **Backend:** pgTAP for RLS (user A cannot read user B's steps; non-member cannot read a board; non-admin cannot change settings).
- **Integration guidance (manual or `integration_test`):** health permission grant/deny/revoke, group create → invite → join → board update, chat send/delete/report, account deletion end-to-end (verify rows and files gone).
- **CI:** add a GitHub Actions workflow running `flutter analyze` and `flutter test`; migrations applied to a scratch Supabase branch.
