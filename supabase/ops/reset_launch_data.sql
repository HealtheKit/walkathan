-- =====================================================================
-- Walkathon launch reset  (DRAFT: NOT EXECUTED, NOT YET TESTED)
-- Project: wyxfvskltoraontczdxf
--
-- WHAT IT DOES
--   1. Counts everything it would remove and records it in ops.reset_log.
--   2. If p_dry_run = false: truncates app data tables, deletes ALL
--      auth users (accounts, sessions, identities), bumps the reset epoch.
--   3. Never touches: schema, functions, policies, migrations,
--      platform_admin_emails (seed data), app_config keys other than
--      reset_epoch, ops.reset_log.
--
-- WHAT IT DOES NOT DO
--   * Storage FILES. Deleting rows from storage.objects does not remove
--     the files (and Supabase blocks it). Empty buckets via dashboard/API.
--     This script only REPORTS the object count; verify_reset.sql checks 0.
--   * Anything on user devices (handled by reset_epoch in the app).
--
-- SAFETY
--   * Lives in schema "ops", which is not exposed through the API.
--   * EXECUTE is revoked from public/anon/authenticated.
--   * Refuses API sessions (session_user = 'authenticator').
--   * Requires the exact confirmation string below.
--   * Defaults to DRY RUN.
--   * PERMANENT once run with p_dry_run => false. Only a backup restores it.
--
-- USAGE (SQL Editor, as postgres)
--   select ops.reset_launch_data('RESET wyxfvskltoraontczdxf');            -- dry run
--   select ops.reset_launch_data('RESET wyxfvskltoraontczdxf', false);     -- REAL
-- =====================================================================

create schema if not exists ops;
revoke all on schema ops from public, anon, authenticated;

create table if not exists ops.reset_log (
  id            bigint generated always as identity primary key,
  run_at        timestamptz not null default now(),
  run_by        text        not null default session_user,
  dry_run       boolean     not null,
  before_counts jsonb       not null,
  after_counts  jsonb,
  note          text
);
revoke all on ops.reset_log from public, anon, authenticated;

create or replace function ops.reset_launch_data(
  p_confirm text,
  p_dry_run boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_expected constant text := 'RESET wyxfvskltoraontczdxf';

  -- Data tables to empty. Seed/reference tables are deliberately absent:
  --   public.platform_admin_emails, public.app_config, ops.reset_log
  c_tables constant text[] := array[
    -- v1 (current) tables
    'users', 'daily_steps',
    -- v2 tables (skipped automatically if they do not exist yet)
    'profiles', 'platform_admins',
    'step_days', 'step_ingest_log', 'period_totals',
    'user_streaks', 'rest_days', 'personal_records', 'user_achievements',
    'friend_prefs', 'user_blocks', 'friendships',
    'message_reports', 'messages', 'dm_messages', 'dm_threads',
    'group_invites', 'group_challenges', 'group_members', 'groups',
    'event_participants', 'events',
    'device_tokens', 'admin_audit_log'
  ];

  v_existing text[] := '{}';
  v_before   jsonb  := '{}'::jsonb;
  v_after    jsonb  := '{}'::jsonb;
  v_t        text;
  v_n        bigint;
  v_log_id   bigint;
begin
  if session_user = 'authenticator' then
    raise exception 'reset is not available through the API';
  end if;

  if p_confirm is distinct from c_expected then
    raise exception 'confirmation string mismatch; expected: %', c_expected;
  end if;

  -- ---- BEFORE counts -------------------------------------------------
  foreach v_t in array c_tables loop
    if to_regclass(format('public.%I', v_t)) is not null then
      v_existing := v_existing || v_t;
      execute format('select count(*) from public.%I', v_t) into v_n;
      v_before := v_before || jsonb_build_object('public.' || v_t, v_n);
    end if;
  end loop;

  select count(*) into v_n from auth.users;
  v_before := v_before || jsonb_build_object('auth.users', v_n);

  if to_regclass('storage.objects') is not null then
    execute 'select count(*) from storage.objects' into v_n;
    v_before := v_before || jsonb_build_object('storage.objects', v_n);
  end if;

  insert into ops.reset_log (dry_run, before_counts, note)
  values (p_dry_run, v_before,
          case when p_dry_run then 'dry run: nothing deleted' else 'REAL RESET started' end)
  returning id into v_log_id;

  if p_dry_run then
    return jsonb_build_object('log_id', v_log_id, 'dry_run', true, 'would_delete', v_before);
  end if;

  -- ---- DELETE --------------------------------------------------------
  -- One TRUNCATE for all existing tables. No CASCADE on purpose: if some
  -- table outside this list references them, this fails loudly instead
  -- of silently wiping it.
  if array_length(v_existing, 1) is not null then
    execute 'truncate table '
      || (select string_agg(format('public.%I', x), ', ') from unnest(v_existing) as x)
      || ' restart identity';
  end if;

  -- Accounts, identities, sessions, refresh tokens (FKs cascade inside auth).
  delete from auth.users;

  -- Make every installed app drop its local cache and sign out.
  if to_regclass('public.app_config') is not null then
    execute $q$
      insert into public.app_config (key, value)
      values ('reset_epoch', to_jsonb(now()::text))
      on conflict (key) do update set value = excluded.value
    $q$;
  end if;

  -- ---- AFTER counts --------------------------------------------------
  foreach v_t in array v_existing loop
    execute format('select count(*) from public.%I', v_t) into v_n;
    v_after := v_after || jsonb_build_object('public.' || v_t, v_n);
  end loop;
  select count(*) into v_n from auth.users;
  v_after := v_after || jsonb_build_object('auth.users', v_n);

  update ops.reset_log
     set after_counts = v_after, note = 'REAL RESET completed'
   where id = v_log_id;

  return jsonb_build_object('log_id', v_log_id, 'dry_run', false,
                            'deleted', v_before, 'remaining', v_after);
end;
$$;

revoke all on function ops.reset_launch_data(text, boolean) from public, anon, authenticated;
