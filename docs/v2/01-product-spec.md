# Walkathon v2: Target Product Specification

Audience: app owner and developers. Status: **draft for approval**. Nothing here is built yet.

## 0. Decisions and assumptions

| # | Decision | Source |
|---|---|---|
| D1 | Project `wyxfvskltoraontczdxf` is the target. Everything is erased by the launch reset (all accounts, steps). | You |
| D2 | Gender-based boards are retired. Rankings are friends, groups, event, country and global. | You |
| D3 | Sign-in is **email and password only**. No Google, Apple or Facebook. | You |
| D6 | **No public sign-up.** The Super Admin adds members. Self-registration is switched off in Supabase Auth. | You |
| D7 | **Household accounts:** one email login holds **up to 6 walker profiles** (self, spouse, child 1 to 3, other). Steps, goals and leaderboard entries belong to a *profile*. | You |
| D8 | **Events repeat.** The Super Admin can run events any number of times; each is a date slot (start to end). | You |
| D9 | A **default Super Admin** is seeded by email at launch (`ops.seed_super_admin`). **Email still to be confirmed.** | You |
| D4 | Country comes from the user's choice at onboarding (default from device locale). **Never GPS.** | You |
| D5 | **Events replace the monthly-on-the-3rd period.** A Super Admin defines an Event (name, start date, end date). The walkathon leaderboard counts steps within it. | You |
| A1 | **Decision (revised again):** events are **roster-based**. The Super Admin bulk-imports each event's members from a CSV email list (`email` or `email,name`). Unknown emails get an account with a one-time temporary password; known emails are just added. Every profile on a rostered account takes part. Built: migration 0005, `bulk_import` in the `admin-members` function, Events screens. | You |
| A2 | **Assumption:** one event is *active* at a time. Others can be *scheduled*, and a Super Admin can create several slots at once (an event *series*) or duplicate a past event. Each run has its own fresh leaderboard; results of ended events stay readable. | D8 |
| A9 | **Decision (tightened):** a phone feeds **one profile, full stop** (not per day). It can move to another household profile only within an hour of first use or after 7 idle days; identical same-day totals across household profiles are rejected. Original note: a phone feeds one profile per day. A spouse or child uses their own phone (signing in with the household email and picking their profile). One device cannot credit steps to two profiles on the same local day. | Prevents double counting |
| A3 | **Assumption:** the event board exists globally, per country, and as a tab inside every group. Daily and weekly boards are unchanged. | Reasonable reading of D5 |
| A4 | **Assumption:** personal monthly and yearly *recaps* stay calendar-based. Only leaderboards use events. | Spec A9 |
| A5 | **Assumption:** friendship needs acceptance (request, accept). Once accepted, both can see each other's steps unless one hides the other. | Safer than one-way visibility |
| A6 | **Assumption:** joining a group means consenting to share daily steps with that group's members. The join screen says so. | Privacy |
| A7 | Day and week boundaries use **each user's own time zone**. Weeks start Monday (locale override later). "Today" on a board is each member's own local today. | Spec G8 |
| A8 | Super Admin accounts are seeded **by verified email** at reset time. **I need the email(s).** | Bootstrap |

If you disagree with A1 to A4, tell me before Phase 1. They change the data model.

## 1. Roles

| Role | Scope | Can |
|---|---|---|
| **Super Admin** | Platform | Create, edit, end events. View platform sync-health and moderation reports. Cannot read private steps. |
| **Household account** | One email login | Manage up to 6 profiles; choose which profile is walking on this device. Is *not* itself a walker. |
| **Group Owner** | One group | Everything an admin can, plus transfer ownership and delete the group. |
| **Group Admin** | One group | Edit settings, toggle chat/taunts/Mystery Mode, create or clear a challenge, export reports, delete messages, remove members. |
| **Member** | One group | View boards, chat if enabled, leave. |
| **User** | Self | Own data, friends, blocks, privacy, deletion. |

All checks are enforced in the database (RLS and `SECURITY DEFINER` functions). The client hides controls for convenience only.

## 2. Screens and navigation

Bottom navigation (phone) or rail (tablet), reusing `AppShell`:

- **Home:** today's ring (steps vs goal), distance, calories, floors (only if the platform provides them), streak, bots, quick actions.
- **Activity:** day / week / month / year tabs, calendar history, recaps, records, achievements.
- **Social:**
  - Friends: list, requests, add by link or handle, friend profile, daily/weekly leaderboard.
  - Groups: list; group detail with Board / Chat / Members; Group Settings; admin entry (long-press group name).
  - Event: active event board (global, country), join and consent.
- **Profile:** photo, name, country, optional body details, goal, privacy, language, notifications, bots, Help & Feedback, delete account.
- **Auth:** sign in and reset password only (no sign-up screen; it shows "ask your administrator to add you"). First login: set a new password, add or confirm profiles, consent notice.
- **Profile switcher:** top-bar chip to change which profile is walking on this device.
- **Admin (Super Admin only):** Members (add by email, resend invite, disable, delete), Events (create, series, duplicate, end), reports queue.

Deep links: `https://<domain>/g/<token>` (group invite), `/f/<token>` (friend invite), `/auth-callback`. Unauthenticated users follow the link, sign in, then land on the join screen.

## 2b. What counts as a valid step

Only steps from a person actually walking or running count.

| Case | Behaviour | How |
|---|---|---|
| Manually typed steps | Never counted | Manual entries are excluded at the source; there is no entry screen |
| Cycling (indoor or outdoor), exercise bike | **Not counted** | Steps recorded during sessions the health platform labels cycling are subtracted |
| Rowing machine, elliptical, stair-climbing machine | **Not counted** | Same mechanism |
| Everyday steps with no logged session (pacing at home, office) | **Counted** | There is no way to classify them without location data |
| Treadmill and other indoor walking/running **sessions** | **Not counted** (your decision) | Android: treadmill workout types. iOS: sessions carrying Apple's indoor flag (`HKIndoorWorkout`); iOS has no separate treadmill type. Unverified on a device |
| Standing still | Not counted | Left to Apple's and Google's step algorithms, which only count walking-like motion. No extra filter is added because it would also undercount real walking |
| Raw phone sensor on a day the Health app has data | Ignored | The sensor cannot know about bike sessions, so the Health total is the only one kept |

**Limits (stated honestly):** there is no GPS, so we cannot prove a person travelled. Exclusion depends on the user's watch or app logging the session, and on granting Exercise read access. A phone-only user on an exercise bike with no logged session cannot be detected. If a stricter guarantee is wanted, options are an Activity Recognition gate or hourly step uploads with server-side cadence checks (see the Phase 2b note in the plan).

## 3. Data model (PostgreSQL)

All tables have RLS **enabled with no default access**. Access goes through the policies and functions listed. Times are `timestamptz`; calendar days are `date` in the user's local zone.

**Identity**
- `profiles(id, account_id → auth.users, relation ∈ self/spouse/child/other, display_name, photo_path, country_code, timezone, locale, height_cm, weight_kg, birth_year, sex, daily_goal default 8000, steps_visibility default 'private', ads_free bool, created_at, deleted_at)`. The email stays only in `auth.users` (not copied). Unique `self` per account; a trigger caps an account at **6** profiles.
- `platform_admins(user_id)` and `platform_admin_emails(email)`. A trigger promotes a user only when the email is **verified**.
- `app_config(key, value)`: includes `reset_epoch`, used to make apps clear local caches after a reset.

**Activity** (written only by `ingest_steps`, never directly by clients)
- `step_days(profile_id, local_date, steps, distance_m, kcal, floors null, tz, source, updated_at, PK(profile_id, local_date))`
- `step_day_sources(profile_id, local_date, source, steps, distance_m, kcal, floors, tz, updated_at)`: one total per source; `step_device_days(device_id, local_date, profile_id)`: one device credits one profile per local day. **Built (migration 0003).** Idempotency comes from uploading *day totals* (re-sending is harmless), not from per-record hashes.
- `period_totals(profile_id, period, period_key, steps, PRIMARY KEY(profile_id, period, period_key))`: incremental running totals for `day`, `week`, `event:<id>`; this is what keeps boards fast.
- `user_streaks(profile_id, current, best, last_goal_date)`, `rest_days(profile_id, local_date)`, `personal_records(profile_id, kind, value, achieved_on)`, `user_achievements(profile_id, code, earned_at)`.

**Social**
- `friendships(profile_a, profile_b, status, requested_by, created_at)` with `profile_a < profile_b` and a unique pair; `friend_prefs(owner_profile, friend_profile, hidden)`; `user_blocks(blocker_profile, blocked_profile)`. All social relations are between **profiles**.
- `groups(id, name, owner_id, chat_enabled, taunts_enabled, mystery_mode, photos_enabled, member_count, created_at)`
- `group_members(group_id, profile_id, role, joined_at)`, indexed on `(profile_id)`. Walkers (profiles) join groups, not logins.
- `group_invites(id, group_id, token_hash, created_by, expires_at, max_uses, uses, revoked_at)`: tokens are random 128-bit and stored hashed.
- `group_challenges(group_id, start_date, end_date, cleared_at)` with `CHECK (end_date - start_date + 1 BETWEEN 1 AND 366)`.
- `events(id, series_id null, name, description, starts_on, ends_on, status, created_by)`; participation is automatic (A1), so there is no opt-in table. Totals live in `period_totals` under `event:<id>`.

**Chat and safety**
- `messages(id, group_id, sender_profile_id, kind, body, media_path, thumb_path, created_at, deleted_at, deleted_by)`. `kind` ∈ text, photo, gif, cheer, taunt, nudge.
- `message_reports(id, message_id, reporter_id, reason, status)`
- `dm_threads` / `dm_messages`: **Phase 6b** (see section 7).

**Operational**
- `device_tokens(account_id, token, platform, locale, last_seen)` (a device belongs to the login; the active profile is chosen in the app)
- `admin_audit_log(id, actor_id, action, target, details, at)`
- `ops.reset_log(...)` (see the reset runbook)

## 4. API / service contract

Clients call Postgres functions (RPC) or Edge Functions. Every one authorizes with `auth.uid()` server-side.

| Function | Who | Purpose |
|---|---|---|
| `ingest_steps(profile_id, device_id, days jsonb)` | User | **Built and tested.** Idempotent import of day totals. Validates plausibility (100,000 steps/day cap; at most 4 steps/second since local midnight for today; no future days; nothing older than 31 days; source must be sensor/health store). A stale lower upload never reduces a total. Takes the **max across sources per day** (never the sum). Updates `step_days`, `period_totals`, streaks, achievements. |
| `my_summary(range)` | User | Daily/weekly/monthly/yearly series. |
| `friend_board(period)` | User | Only accepted, non-hidden, non-blocked friends. |
| `group_board(group_id, period, limit, offset)` | Member | Top N + the caller's own rank. Applies Mystery Mode. |
| `event_board(event_id, scope, limit, offset)` | Participant | Scope = global / country / group. |
| `create_group`, `update_group_settings`, `remove_member`, `set_role` | Owner/Admin | Group management. |
| `create_invite`, `revoke_invite`, `redeem_invite(token)` | Admin / User | Invites (rate-limited). |
| `set_challenge`, `clear_challenge` | Admin | 1 to 366 days. |
| `send_message`, `delete_message`, `report_message` | Member / Admin | Chat. |
| `admin_create_event`, `admin_create_event_series(name, slots)`, `admin_update_event`, `admin_end_event` | Super Admin | Event lifecycle; a series creates one event per date slot. |
| `admin_list_members()` | Super Admin | Emails, activity, profile counts. **Built and tested** (migration 0001). |
| `admin-members` Edge Function (create / invite / disable / delete / resend / reset password) | Super Admin | Service-role account management. Authorizes the caller as Super Admin first. |
| `add_profile`, `update_profile`, `delete_profile` | Account owner | Household profiles (cap 6, one `self`). Direct table access is allowed by RLS for these. |
| `export_group_report(group_id, from, to)` | Edge Function, Admin | CSV. Audited. |
| `delete_account` | Edge Function, User | Service-role deletion of profile, data, storage files, tokens. |
| `send_push` | Edge Function, internal | FCM fan-out. |
| `moderate_photo` | Edge Function, optional | Phase 6b. |

## 5. Privacy model

1. **Default private.** No other user can read `step_days`, `period_totals`, or the profile body details. There is no table-level read access for other users, only through functions that check relationships.
2. **Friends:** an accepted friendship shares display name, photo and step activity both ways, unless hidden or blocked. Removing a friend or blocking ends access immediately.
3. **Groups:** members see each other's display name, photo and period steps in that group's boards. The consent text is shown before joining.
4. **Mystery Mode:** today's step counts are hidden from the board (ranks only) until the next day.
5. **Country and global boards:** show display name and steps only for users who opted into an event. The "top 100 in country" achievement is computed server-side from event totals, so no per-user location is needed.
6. **Health data:** never in logs, analytics, crash reports, or ad requests. Ads SDK never receives health data or user ids.
7. **Children's data.** Profiles marked `child` (or under 18 by birth year) belong to the parent's account, who controls them. Recommendation: no personalised ads while the account has a child profile, no direct messages or open group chat for child profiles, and a clear parental-consent notice when adding one. Check your local rules (for example India's DPDP Act requires verifiable parental consent for children's data). This is not legal advice, so please have the privacy policy reviewed.
8. Height, weight, age and sex are optional, stay on the profile, and are never visible to others.

## 6. Offline, notifications, localization, errors

- **Offline:** the app keeps a local queue of unsent step windows and retries with backoff. The upload is idempotent, so replays are safe. Screens show the last cached data with a "last synced" label.
- **Notifications (FCM):** goal reached, streak at risk, friend request, group invite accepted, nudge/cheer/taunt, event start/end, daily recap. Every category can be turned off. Taunts and nudges respect the group's setting and blocks.
- **Localization:** `flutter_localizations` plus ARB files for English, Tamil, Hindi (`lib/l10n/`). Adding a language = adding one `.arb` file. Native-speaker review before release.
- **Edge cases handled:** duplicate imports (idempotency key), device change (data is per-user, not per-device; max-per-source per day), time-zone travel (each `step_days` row stores its own `tz` and local date), missing data (gaps shown as gaps, not zeros), delayed health-store sync (late windows overwrite the day with the higher value), clock changes (server timestamps, future windows rejected).

## 7. Feature decisions

- **Direct messages:** feasible but doubles the moderation surface. Recommended as **Phase 6b**, after group chat is stable, reusing the same tables pattern and blocks.
- **Team vs team:** one group per team, plus admin CSV export. No direct group-vs-group board.
- **Moderation (recommended):** report message, block user, admin delete, per-group switches for chat/taunts/photos, private storage with signed URLs, client-side image resize and thumbnails, rate limits. Automated photo moderation is **optional and off by default**, because it sends images to a third party. If enabled later, use an Edge Function and disclose it in the privacy policy.
- **Bots:** Active (10,000/day), Chill (2,000/day), Yesterday (your steps at the same time yesterday). Hide toggle per user. Computed on the client from cached data.
- **Widgets / live notification:** Android home-screen widget and iOS WidgetKit extension fed from a local snapshot. These need native code (Phase 7).
- **Ads / IAP:** AdMob with Google's consent flow (UMP); one non-consumable "Remove ads" product via `in_app_purchase`. Core features stay free.
