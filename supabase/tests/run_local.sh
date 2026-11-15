#!/usr/bin/env bash
# Runs the migrations and authorization tests against a THROWAWAY local
# PostgreSQL cluster with stand-in Supabase objects. Never touches a real
# project. Usage: supabase/tests/run_local.sh [scratch_dir]
set -euo pipefail
cd "$(dirname "$0")/../.."
S="${1:-$(mktemp -d)}"
PORT=55433

pg_ctl -D "$S/pg" stop >/dev/null 2>&1 || true
rm -rf "$S/pg"
initdb -D "$S/pg" -U postgres >/dev/null
pg_ctl -D "$S/pg" -o "-p $PORT -k ''" -l "$S/pg.log" -w start >/dev/null
trap 'pg_ctl -D "$S/pg" stop >/dev/null 2>&1 || true' EXIT

p() { psql -h 127.0.0.1 -p $PORT -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
p -d postgres -c "create database t"

# Stand-ins for what Supabase provides.
p -d t <<'EOF'
create role anon nologin; create role authenticated nologin; create role service_role nologin;
create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(), email text,
  email_confirmed_at timestamptz, created_at timestamptz default now(), last_sign_in_at timestamptz, banned_until timestamptz,
  raw_user_meta_data jsonb default '{}'::jsonb);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated;
grant usage on schema public to anon, authenticated, service_role;
grant usage on schema auth to service_role;
-- Supabase grants ALL on new public tables to these roles; mimic that so the
-- migration's explicit REVOKEs are what's under test.
alter default privileges in schema public grant all on tables to anon, authenticated;
-- v1 objects, as they exist today
create table public.users (id uuid primary key references auth.users on delete cascade, name text, email text, gender text);
create table public.daily_steps (id bigserial primary key, user_id uuid references public.users, date_key text);
EOF

for f in supabase/migrations/0001_foundation.sql supabase/migrations/0003_steps.sql supabase/migrations/0004_rest_days.sql supabase/migrations/0005_events.sql supabase/migrations/0006_device_binding.sql supabase/migrations/0007_event_board.sql supabase/migrations/0008_friends.sql supabase/migrations/0009_groups.sql supabase/migrations/0010_scoring.sql supabase/migrations/0011_profile_transfer.sql supabase/migrations/0012_count_integrity_reset.sql; do p -d t -f "$f"; done
p -d t -f supabase/tests/0001_foundation_test.sql
p -d t -f supabase/tests/0003_steps_test.sql
p -d t -f supabase/tests/0004_rest_days_test.sql
p -d t -f supabase/tests/0005_events_test.sql
p -d t -f supabase/tests/0006_device_binding_test.sql
p -d t -f supabase/tests/0007_event_board_test.sql
p -d t -f supabase/tests/0008_friends_test.sql
p -d t -f supabase/tests/0009_groups_test.sql
p -d t -f supabase/tests/0010_scoring_test.sql
p -d t -f supabase/tests/0011_profile_transfer_test.sql
p -d t -f supabase/tests/0012_count_integrity_test.sql
# 0013 changes who may upload (a new phone needs approval), so the older
# suites above run first, against the behaviour they were written for.
p -d t -f supabase/migrations/0013_device_login.sql
p -d t -f supabase/tests/0013_device_login_test.sql
p -d t -f supabase/migrations/0014_organizer_one_profile.sql
p -d t -f supabase/tests/0014_organizer_one_profile_test.sql
p -d t -f supabase/migrations/0015_super_admin_any_phone.sql
p -d t -f supabase/tests/0015_super_admin_any_phone_test.sql
p -d t -f supabase/migrations/0016_reset_own_day.sql
p -d t -f supabase/tests/0016_reset_own_day_test.sql
p -d t -f supabase/migrations/0017_reset_by_time.sql
p -d t -f supabase/tests/0017_reset_by_time_test.sql
p -d t -f supabase/migrations/0018_fresh_start.sql
p -d t -f supabase/tests/0018_fresh_start_test.sql
# Seed script: existing verified account is promoted now; future one on creation.
p -d t -f supabase/ops/seed_super_admin.sql
p -d t -At <<'EOSQL'
insert into auth.users (id, email, email_confirmed_at) values ('44444444-4444-4444-4444-444444444444','owner@example.com', now());
do $$ begin
  assert (ops.seed_super_admin(' Owner@Example.com ') ->> 'promoted_now')::boolean, 'existing verified account promoted';
  assert (select count(*) from public.platform_admins where user_id = '44444444-4444-4444-4444-444444444444') = 1;
  perform ops.seed_super_admin('owner@example.com');  -- idempotent
  perform ops.seed_super_admin('later@example.com');
  insert into auth.users (id, email, email_confirmed_at) values ('55555555-5555-5555-5555-555555555555','later@example.com', now());
  assert (select count(*) from public.platform_admins where user_id = '55555555-5555-5555-5555-555555555555') = 1, 'future account promoted on creation';
  begin perform ops.seed_super_admin('not-an-email'); assert false; exception when raise_exception then null; end;
end $$;
EOSQL
echo "seed tests passed"
set +e
out=$(p -d t -c "set role authenticated; select ops.seed_super_admin('x@y.zz')" 2>&1 || true)
case "$out" in *"permission denied for schema ops"*) echo "seed denied to authenticated: ok";; *) echo "FAIL: authenticated can reach ops"; exit 1;; esac
set -e
p -d t -f supabase/migrations/0002_retire_v1.sql
p -d t -c "select to_regclass('public.users') is null and to_regclass('public.daily_steps') is null as v1_dropped" -At

# The single-paste launch file must work on its own against a fresh database
# that still has the v1 tables (what the live project looks like today).
p -d postgres -c "create database t2"
p -d t2 <<'EOF2'
create role dummy_unused nologin;
create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(), email text,
  email_confirmed_at timestamptz, created_at timestamptz default now(), last_sign_in_at timestamptz, banned_until timestamptz,
  raw_user_meta_data jsonb default '{}'::jsonb);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated;
grant usage on schema public to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
create table public.users (id uuid primary key references auth.users on delete cascade, name text, email text, gender text);
create table public.daily_steps (id bigserial primary key, user_id uuid references public.users, date_key text);
insert into auth.users(email) values ('old@example.com');
insert into public.users select id,'Old','old@example.com','male' from auth.users;
EOF2
p -d t2 -f supabase/launch_all.sql >/dev/null
p -d t2 -At -c "select to_regclass('public.profiles') is not null, to_regclass('public.step_days') is not null, to_regclass('public.users') is null, to_regprocedure('ops.seed_super_admin(text)') is not null, to_regprocedure('public.ingest_steps(uuid,text,jsonb)') is not null" | grep -q "t|t|t|t|t" && echo "launch_all.sql: applies cleanly on a v1-shaped database" || { echo "FAIL: launch_all.sql"; exit 1; }
# the read-only health check must run on a set-up database
p -d t2 -At -f supabase/ops/health_check.sql | head -4
# a signup after setup must produce a profile
p -d t2 -At -c "insert into auth.users(email) values ('new@example.com'); select count(*) from public.profiles" | grep -q "1" && echo "signup trigger creates a profile after launch_all.sql"
