-- =====================================================================
-- Read-only health check for the live project. Paste into the SQL Editor
-- (set "No limit"). Every row should say ok = true.
-- =====================================================================
with checks(item, ok, fix) as (
  values
  ('table profiles',            to_regclass('public.profiles') is not null,            'run supabase/launch_all.sql'),
  ('table platform_admins',     to_regclass('public.platform_admins') is not null,     'run supabase/launch_all.sql'),
  ('table app_config',          to_regclass('public.app_config') is not null,          'run supabase/launch_all.sql'),
  ('table feedback',            to_regclass('public.feedback') is not null,            'run supabase/launch_all.sql'),
  ('table admin_audit_log',     to_regclass('public.admin_audit_log') is not null,     'run supabase/launch_all.sql'),
  ('table step_days',           to_regclass('public.step_days') is not null,           'run supabase/migrations/0003_steps.sql'),
  ('table step_day_sources',    to_regclass('public.step_day_sources') is not null,    'run supabase/migrations/0003_steps.sql'),
  ('table period_totals',       to_regclass('public.period_totals') is not null,       'run supabase/migrations/0003_steps.sql'),
  ('table rest_days (Phase 3)', to_regclass('public.rest_days') is not null,           'run supabase/migrations/0004_rest_days.sql'),
  ('table events',              to_regclass('public.events') is not null,              'run supabase/migrations/0005_events.sql'),
  ('table event_accounts',      to_regclass('public.event_accounts') is not null,      'run supabase/migrations/0005_events.sql'),
  ('table profile_devices',     to_regclass('public.profile_devices') is not null,     'run supabase/migrations/0006_device_binding.sql'),
  ('function event_board',      to_regprocedure('public.event_board(uuid,text,date,int)') is not null, 'run supabase/migrations/0007_event_board.sql'),
  ('table friendships (Phase 4)', to_regclass('public.friendships') is not null,   'run supabase/migrations/0008_friends.sql'),
  ('table groups (Phase 5)',    to_regclass('public.groups') is not null,              'run supabase/migrations/0009_groups.sql'),
  ('scoring and admin (0010)',  to_regprocedure('public.admin_event_overview(uuid,date)') is not null, 'run supabase/migrations/0010_scoring.sql'),
  ('old table users removed',       to_regclass('public.users') is null,               'run supabase/migrations/0002_retire_v1.sql'),
  ('old table daily_steps removed', to_regclass('public.daily_steps') is null,         'run supabase/migrations/0002_retire_v1.sql'),
  ('function ingest_steps',     to_regprocedure('public.ingest_steps(uuid,text,jsonb)') is not null, 'run supabase/migrations/0003_steps.sql'),
  ('function is_platform_admin',to_regprocedure('public.is_platform_admin()') is not null,           'run supabase/launch_all.sql'),
  ('function admin_list_members',to_regprocedure('public.admin_list_members()') is not null,         'run supabase/launch_all.sql'),
  ('function ops.seed_super_admin', to_regprocedure('ops.seed_super_admin(text)') is not null,       'run supabase/ops/seed_super_admin.sql'),
  ('signup trigger on auth.users',
     exists (select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_created'),
     'run supabase/launch_all.sql'),
  ('admin-promotion trigger on auth.users',
     exists (select 1 from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_admin_sync'),
     'run supabase/launch_all.sql'),
  ('RLS enabled on every public table',
     not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
     'a public table has RLS off: tell the developer which'),
  ('a Super Admin email is seeded',
     (select count(*) from public.platform_admin_emails) > 0,
     'select ops.seed_super_admin(''<email>'')'),
  ('the Super Admin login exists and is verified',
     exists (select 1 from auth.users u join public.platform_admin_emails e on lower(u.email) = e.email
             where u.email_confirmed_at is not null),
     'Authentication > Users > Add user (tick Auto Confirm User)'),
  ('the Super Admin is promoted',
     (select count(*) from public.platform_admins) > 0,
     'select ops.seed_super_admin(''<email>'') after the login exists'),
  ('every account has a self profile',
     not exists (select 1 from auth.users u
                 where not exists (select 1 from public.profiles p
                                   where p.account_id = u.id and p.relation = 'self')),
     'old accounts without a profile: run the launch reset, or ask for a backfill')
)
select item, ok, case when ok then '' else fix end as how_to_fix
from checks
order by ok, item;
