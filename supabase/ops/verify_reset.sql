-- =====================================================================
-- Read-only inventory and verification queries.
-- Safe to run any time (SELECT only). Run SECTION A before the reset,
-- SECTION B after it.
-- =====================================================================

-- ---------- SECTION A: pre-reset inventory (no personal data printed) ----------

-- A1. Tables in public with row estimates and whether RLS is on
select c.relname              as table_name,
       c.reltuples::bigint    as approx_rows,
       c.relrowsecurity       as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;

-- A2. Accounts: totals and recent activity (counts only)
select count(*)                                                     as total_accounts,
       count(*) filter (where last_sign_in_at > now() - interval '30 days') as active_30d,
       count(*) filter (where email_confirmed_at is null)           as unconfirmed
from auth.users;

-- A3. Step data volume
select count(*) as step_rows, min(date_key) as first_day, max(date_key) as last_day
from public.daily_steps;

-- A4. Storage buckets and object counts (files must be emptied via the API/dashboard)
select b.name as bucket, count(o.id) as objects
from storage.buckets b
left join storage.objects o on o.bucket_id = b.id
group by b.name order by b.name;

-- A5. Existing policies (to confirm the v1 "read everything" problem)
select schemaname, tablename, policyname, cmd, qual
from pg_policies where schemaname = 'public' order by tablename, policyname;

-- ---------- SECTION B: post-reset verification ----------

-- B1. Every data table empty; auth users empty. Expect all zeros.
select 'auth.users' as item, count(*) as n from auth.users
union all select 'auth.identities', count(*) from auth.identities
union all select 'auth.sessions', count(*) from auth.sessions
union all select 'public.users (v1)', count(*) from public.users
union all select 'public.daily_steps (v1)', count(*) from public.daily_steps;
-- After Phase 1 also check: profiles, step_days, groups, messages, device_tokens, ...

-- B2. Storage empty. Expect no rows with objects > 0.
select b.name as bucket, count(o.id) as objects
from storage.buckets b left join storage.objects o on o.bucket_id = b.id
group by b.name having count(o.id) > 0;

-- B3. The reset was logged (latest row, REAL RESET completed).
select id, run_at, run_by, dry_run, note, before_counts, after_counts
from ops.reset_log order by id desc limit 3;

-- B4. Schema preserved: RLS still enabled everywhere. Expect NO rows.
select c.relname as table_without_rls
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

-- B5. Seed data preserved (after Phase 1). Expect the Super Admin emails you provided.
-- select count(*) from public.platform_admin_emails;
-- select key, value from public.app_config where key = 'reset_epoch';
