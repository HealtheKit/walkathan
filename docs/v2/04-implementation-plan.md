# Walkathon v2: Implementation Plan

Effort assumes one experienced Flutter/Postgres developer (person-weeks). Each phase ends with your approval before the next starts.

| Phase | Goal | Main work | Acceptance | Risks | Effort |
|---|---|---|---|---|---|
| **0 Audit and reset** | Clean, launch-ready database | Reset runbook and scripts (done in draft), backup, run reset, seed `reset_epoch` and Super Admin emails | Verification queries all zero/expected; app launches to sign-in | Irreversible deletion; testers lose accounts | 0.5 |
| **1 Auth, household profiles, admin members** | Secure foundation | Migration `0001` (done, tested): household `profiles` (max 6), RLS default-deny, Super Admin, `admin_list_members`; `0002` drops v1. Remaining: email-only sign-in (remove sign-up), `admin-members` Edge Function and Members screen, profile switcher and add/edit/delete profiles, first-login flow and consent, privacy screen, Help and Feedback, account deletion, reset-epoch cache clear | A cannot read B; only Super Admin can add members; 7th profile rejected; deletion removes all rows/files | Custom SMTP needed for invites | 3 |
| **2 Steps and health** | Correct tracking | `health_source`s; delta logic; local queue; `ingest_steps`; idempotency; platform permission strings and entitlement | Phone-only and Health Connect/HealthKit days match platform apps within tolerance; offline then online sync; no duplicates | Gradle/plugin conflicts, OEM battery limits | 4 |
| **3 Goals and history** | Personal progress | Goal, day/week/month/year, calendar, recaps, streaks, rest days, records, achievements | Boundary tests across zones/DST pass | Calorie accuracy expectations | 3 |
| **4 Friends and boards** | Social basics | Friendships, hide/block, friend profile, daily/weekly friend board | Hidden/blocked users disappear from boards at once | Abuse of add-by-link | 2.5 |
| **5 Groups and events** | Core competition | Groups, roles, invite links, challenges (1 to 366 days), Mystery Mode, repeatable `events` (date slots, series, duplicate) + Super Admin editor, event boards, admin CSV export | 15,000-member load test; Mystery counts never reach client; non-admin blocked server-side | Board performance, link abuse | 5 |
| **6 Chat and safety** | Engagement | Messages, photos, GIF links, cheers/taunts/nudges, report/block/delete, per-group switches; 6b: DMs | Disabled chat/taunts enforced server-side; deleted messages gone for everyone | Moderation workload, storage cost | 4 (+2 for DMs) |
| **7 Bots, notifications, widgets, sharing** | Motivation | Bots, FCM, notification settings, share card, Android widget, iOS WidgetKit | Widgets update; opt-outs respected | Native code; iOS widget extension | 4 |
| **8 Ads, IAP, localization** | Release features | AdMob + consent, Remove-ads purchase, en/ta/hi ARB | No health data in ad requests; consent before personalized ads | Store review of IAP and ads | 2.5 |
| **9 QA and release** | Ship | Performance, security review, accessibility, store listings, privacy policy, Data safety form, launch checklist | Checklist green | Review rejections | 3 |

**Total about 33 person-weeks** (7 to 8 months solo; less with a team). Phase 1 can start as soon as you approve the spec and the reset has run.

## Per-phase files and tests (summary)

- **1:** `supabase/migrations/0001_foundation.sql`, `features/profile/*`, `features/auth/*`, Edge Function `delete-account`. Tests: pgTAP RLS, widget tests for sign-in and delete flow.
- **2:** `features/health/*`, `core/sync/*`, `core/time/*`, native config edits. Tests: delta/boot logic, idempotent ingest, permission-denied UI.
- **3:** `features/activity/*`, `features/gamification/*`. Tests: streak/rest-day, period-key and DST cases.
- **4–5:** `features/friends/*`, `features/groups/*`, `features/events/*`, `features/admin/*`, migrations `0004`–`0005`. Tests: pgTAP authorization matrix, board pagination, Mystery Mode.
- **6:** `features/chat/*`, bucket policies, `moderate-photo` (optional). Tests: rate limit, report flow.
- **7–8:** `core/push/*`, widget extensions, `features/ads/*`, `l10n/*`.
- **9:** CI workflow, load-test scripts, release docs.

## Launch checklist (summary; expanded at Phase 9)

Permissions and rationale strings (Activity Recognition, Health Connect, HealthKit, Motion, notifications) · Play Health Connect declaration and Data safety form · App Privacy labels · privacy policy and in-app deletion · crash reporting and analytics (no health data) · ads consent and `remove_ads` restore · localization review · production reset verified · Super Admin seeded · store listings.

## Phase 2b (optional, not started): stricter movement checks

Only if the rules in the spec (section 2b) prove too easy to cheat. Options, in order of cost:
1. **Hourly uploads** with server-side cadence checks (flag days with hours of constant, implausible cadence). No new permissions.
2. **Activity Recognition gate** (Android Play services / iOS CMMotionActivity): only count sensor steps in windows classified as walking or running. Needs a native receiver, adds battery use, and still cannot identify a stationary bike reliably.
3. **Admin review queue** for flagged days.

## Status log

| Phase | State |
|---|---|
| 0 | Reset script and runbook written and scratch-tested. Real reset not run (owner's choice). Migrations applied to the live project by the owner. |
| 1 | Built and tested. Edge Functions written and type-checked, **not deployed**. First Super Admin login not yet created in the dashboard. |
| 2 | Built and tested. Android debug build and iOS device build succeed (iOS target raised to 15.0). Not yet run on a physical phone. |
| 3 | Built and tested: Activity screen (day/week/month/year, calendar, recaps), streaks with Rest Days (max 2 per week, migration 0004), personal records, achievements. Streaks, records and achievements are derived in the app from stored days (no extra tables); the current goal is applied to past days. |
| 5 (part) | Built early at the owner's request: events as date slots, per-event rosters, bulk CSV import with one-time passwords, admin Events screens. Event leaderboards, groups, invites, challenges and Mystery Mode are still to do. |
| Live count, per-profile phones, event dashboard | Built and tested (not yet run on a phone). Live: the screen follows the phone's step counter between syncs and uploads about every 20 s while walking. One phone = one profile (migration 0006: hardware-scoped device id, binding, mirror rejection). Event dashboard replaces the old leaderboard tab (migration 0007 `event_board`). Home, Walk and the dashboard were redesigned under the impeccable (native, Operate mode) and taste (visual principles only) skills. |
| 4 | Built and tested: friends by personal code or shared event, accept/decline, hide, block (silent), remove, per-profile sharing switch, daily/weekly/monthly friend boards (migration 0008). |
| 5 | Built and tested: private groups (up to 15,000), owner/admin/member roles, hashed expiring invite codes with rate limiting, day/week/month/challenge boards, fixed-date challenges (1 to 366 days, kept after end), Mystery Mode on the group's own clock, admin CSV report, remove members, hand over ownership (migration 0009). Chat and taunt switches are stored for Phase 6. |
| Scoring + dashboards | Built and tested (migration 0010): hourly steps, step and timing consistency, active-day rate, streaks, recovery, weekly comparison, trend and cumulative charts, calendar, personal bests (pace and active minutes are estimates), milestones, badges, reward eligibility; boards by total, average, distance or active days with men's/women's views, percentile, gap to next and event average; staff roles (organizer, verifier, viewer); event lifecycle and rules (daily target, daily cap, reward rules); participant block, reinstate, move, sex; data-quality flags; audited exclude/cap corrections and re-sync requests; in-app announcements by audience; rewards and distribution status; organizer dashboard and CSV report. Not included by decision: age bands, push notifications, virtual routes. |
