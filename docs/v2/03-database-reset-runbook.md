# Database Reset Runbook: project `wyxfvskltoraontczdxf`

> **WARNING: this is permanent.** A real reset deletes every account and all step data. The only way back is a backup you took beforehand. Nothing in this runbook has been run against your project.

## 1. Inventory: what exists and what happens to it

| Item | Today | Action |
|---|---|---|
| `auth.users`, identities, sessions, refresh tokens | Real tester accounts (likely) | **Delete all** |
| `public.users` (names, emails, gender) | v1 profiles | **Delete rows**; table dropped in the Phase 1 migration |
| `public.daily_steps` | v1 step data (unreliable, see audit C1) | **Delete rows**; table dropped in Phase 1 |
| v2 tables (friends, groups, messages, devices, achievements, ...) | Don't exist yet | Emptied by the script if present |
| Chat, direct messages, payments, push tokens, analytics ids | Not present | Nothing to delete now. Script covers them for later runs |
| Storage files | No buckets expected; verify with query A4 | **Empty buckets via API/dashboard** (SQL can't) |
| Schema, functions, RLS policies, migrations | Present | **Preserve** |
| Seed data: `platform_admin_emails`, `app_config` | Created in Phase 1 | **Preserve** (only `reset_epoch` is bumped) |
| `ops.reset_log` | Created by the script | **Preserve** (audit trail) |
| Local caches on phones | SharedPreferences (later SQLite queue) | **Cleared by the app** when `reset_epoch` changes |
| FCM / push tokens | None yet | `device_tokens` truncated; the app deletes its FCM token on epoch change |
| Analytics identifiers | None yet | App resets the analytics user id on epoch change |

## 2. Preconditions (all must be true)

1. You have **explicitly confirmed** "reset all". Recorded: yes, in this conversation.
2. Testers have been told their accounts will be deleted (suggest a message at least 48 h ahead).
3. You have the **Super Admin email(s)** to seed. (Needed for Phase 1, not for the reset itself.)
4. No legal retention duty applies (no payments, no real chat content exist today).
5. A backup exists and has been checked (section 3).
6. `.mcp.json` should be read-only until you are ready (add `&read_only=true`; confirm the parameter in Supabase's MCP docs), then switched back deliberately for the reset step.

## 3. Backup (do not skip)

**Option A: dashboard.** Supabase → Project → Database → Backups. Take or confirm a recent backup; note the time. (Point-in-time recovery is available only on some plans.)

**Option B: command line.** Get the connection string from Project Settings → Database. Keep it out of the repo.

```bash
export DATABASE_URL='postgresql://postgres:<PASSWORD>@db.wyxfvskltoraontczdxf.supabase.co:5432/postgres'
mkdir -p ~/walkathon-backups && cd ~/walkathon-backups
# data + schema for the schemas that matter
pg_dump "$DATABASE_URL" --schema=public --schema=auth -Fc -f "walkathon-$(date +%F-%H%M).dump"
# human-readable copy of app tables
pg_dump "$DATABASE_URL" --schema=public --data-only --inserts -f "public-data-$(date +%F).sql"
# check it is not empty
pg_restore --list walkathon-*.dump | head
ls -lh
```

Store the dump somewhere private. It contains emails and password hashes.

## 4. Run the reset

Use the Supabase **SQL Editor** (runs as `postgres`) or the MCP once it is in write mode.

```sql
-- 0. Install (idempotent). Paste supabase/ops/reset_launch_data.sql and run it.

-- 1. Pre-reset inventory. Paste Section A of supabase/ops/verify_reset.sql. Read the numbers.

-- 2. DRY RUN: counts only, deletes nothing, writes a log row.
select ops.reset_launch_data('RESET wyxfvskltoraontczdxf');

-- 3. REAL RESET: only after you have read the dry-run output and have a backup.
select ops.reset_launch_data('RESET wyxfvskltoraontczdxf', false);
```

Safeguards: the confirmation string must match exactly; the default is a dry run; the function is in a schema the API doesn't expose, with EXECUTE revoked from `anon`/`authenticated`; API sessions are refused. Running it again is harmless (idempotent; second run deletes zero rows).

**Storage (separate step).** If query A4 shows any objects: Dashboard → Storage → open each bucket → select all → delete, or via CLI `supabase storage rm -r ss:///<bucket> --experimental`. Don't `DELETE` from `storage.objects`; it leaves orphaned files.

## 5. Verification

Run Section B of `supabase/ops/verify_reset.sql`:
- B1: all counts `0`.
- B2: returns no rows (storage empty).
- B3: latest `ops.reset_log` row says `REAL RESET completed`, with before and after counts.
- B4: returns no rows (RLS still enabled everywhere).
- B5 (after Phase 1): your Super Admin emails and `reset_epoch` are present.

## 5b. After the reset: bootstrap the Super Admin

The reset deletes **every** account, including any Super Admin, and sign-up is disabled, so nobody can log in until you recreate one:
1. Dashboard → Authentication → Users → **Add user** → enter the email and a strong password, tick **Auto Confirm User**.
2. SQL Editor: `select ops.seed_super_admin('<that email>');` (file: `supabase/ops/seed_super_admin.sql`). It records the email as seed data (kept across future resets) and promotes the account if it is already verified.
3. Dashboard → Authentication → Sign In / Providers → turn **off** "Allow new users to sign up".
4. Sign in to the app with that account; confirm the Admin area appears.

## 6. Post-reset smoke tests

1. Open the app on a phone that had the old build: it should sign out and clear local data (after the epoch check ships in Phase 1; until then, reinstall or clear app data).
2. Sign up a new account → confirm profile row appears → sign in on a second device.
3. Sign in with the Super Admin email → confirm the Admin area is visible; with a normal account → confirm it is not.
4. Steps sync for one day; row visible only to the owner (check by querying as a second user: should return nothing).
5. Delete the test account in-app → confirm `auth.users`, profile, steps and files for it are gone.

## 7. Rollback

| Situation | Possible? |
|---|---|
| Dry run only | Nothing to undo. |
| Real reset, backup exists | **Partly.** Restore the dump into a **scratch project first** and inspect it. Restoring `auth` data into the live project needs matching schema versions, and sessions/tokens are not worth restoring. Plan to have users sign in again. |
| Real reset, no backup | **Not possible.** |

## 8. Irreversible actions (summary)

- `delete from auth.users`: accounts and password hashes are gone for good.
- `truncate ... restart identity`: rows and id counters are reset.
- Emptied storage buckets.

## 9. Who can trigger it

Only someone with the database owner credentials (SQL Editor, `DATABASE_URL`) or an MCP session in write mode. No app user, no anon key, no service-role API call can reach `ops.reset_launch_data`. A future in-app "admin reset" is intentionally **not** provided.

## 10. Testing status

The script was exercised on a throwaway local PostgreSQL using stand-in `auth` and `storage` tables: wrong confirmation is rejected, a dry run deletes nothing, a real run empties the tables and `auth.users`, a second run is a no-op, seed data and the log survive, and `anon` is denied. It has **not** been run against real Supabase, whose `auth`/`storage` schemas differ in details. Run the dry run first and read the output.
