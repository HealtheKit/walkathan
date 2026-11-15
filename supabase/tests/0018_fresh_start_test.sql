\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('a8a8a8a8-0000-0000-0000-000000000001', 'super18@example.com', now()),
  ('a8a8a8a8-0000-0000-0000-000000000002', 'walker18@example.com', now()),
  ('a8a8a8a8-0000-0000-0000-000000000003', 'plain18@example.com', now());
insert into public.platform_admins (user_id) values ('a8a8a8a8-0000-0000-0000-000000000001') on conflict do nothing;
insert into public.events (id, name, starts_on, ends_on) values
  ('a8a8a8a8-eeee-0000-0000-000000000001', 'E18', (now() at time zone 'UTC')::date - 5, (now() at time zone 'UTC')::date + 5);
insert into public.event_accounts (event_id, account_id) values
  ('a8a8a8a8-eeee-0000-0000-000000000001', 'a8a8a8a8-0000-0000-0000-000000000002');

-- shared helpers: the walker's clock is set so "now" is 12:xx local
create or replace function pg_temp.off_min() returns int language sql as
  $$ select (12 - extract(hour from now() at time zone 'UTC')::int) * 60 $$;
create or replace function pg_temp.today() returns text language sql as
  $$ select (((now() at time zone 'UTC') + make_interval(mins => pg_temp.off_min()))::date)::text $$;
create or replace function pg_temp.hrs(variadic p int[]) returns jsonb language sql as $$
  select to_jsonb(array(select coalesce((select p[i + 1] from generate_subscripts(p, 1) i
                                          where i % 2 = 1 and p[i] = h), 0)
                          from generate_series(0, 23) h));
$$;
-- one upload as the phone would send it
create or replace function pg_temp.item(p_source text, p_steps int, p_hours jsonb, p_from timestamptz default null)
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
    'local_date', pg_temp.today(), 'tz_offset_min', pg_temp.off_min(), 'source', p_source,
    'steps', p_steps, 'hours', p_hours, 'observed_at', clock_timestamp(), 'counted_from', p_from)));
$$;
grant execute on all functions in schema pg_temp to authenticated;

select id as w from public.profiles where account_id = 'a8a8a8a8-0000-0000-0000-000000000002' \gset
select id as pl from public.profiles where account_id = 'a8a8a8a8-0000-0000-0000-000000000003' \gset
select set_config('t.w', :'w', false), set_config('t.pl', :'pl', false) \gset

-- ---------- the walker has 5,000 steps today, all before noon ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000002', false) \gset
do $$
declare w uuid := current_setting('t.w')::uuid; r jsonb;
begin
  r := public.ingest_steps(w, 'walker-phone-18', pg_temp.item('health_store', 5000, pg_temp.hrs(8, 3000, 10, 2000)));
  assert r -> 0 ->> 'status' = 'ok', r::text;
  -- claiming "counted from" without any reset is ignored
  r := public.ingest_steps(w, 'walker-phone-18', pg_temp.item('health_store', 5000, pg_temp.hrs(8, 3000, 10, 2000), now()));
  assert r -> 0 ->> 'status' = 'ok', r::text;
end $$;
reset role;
do $$ begin
  assert (select counted_from from public.step_days where profile_id = current_setting('t.w')::uuid) is null,
    'an unbacked counted_from is not stored';
end $$;

-- ---------- Super Admin sets everyone to zero ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000001', false) \gset
do $$
declare e uuid := 'a8a8a8a8-eeee-0000-0000-000000000001';
begin
  assert public.admin_reset_counts(e, null, null, 'fresh start') = 1;
  assert (public.event_board(e, 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null) ->> 'total_steps')::int = 0;
end $$;
reset role;
do $$ begin
  assert (select count_from from public.profiles where id = current_setting('t.w')::uuid) is not null, 'profile told to start fresh';
  assert (select count_from from public.profiles where id = current_setting('t.pl')::uuid) is null, 'other profiles untouched';
end $$;

-- ---------- the phone syncs: first an OLD app (full total, unmarked), then the new app ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000002', false) \gset
do $$
declare w uuid := current_setting('t.w')::uuid; r jsonb; cf timestamptz;
begin
  select count_from into cf from public.profiles where id = w;   -- the app reads this
  -- old app / step access just switched on: the whole day again
  r := public.ingest_steps(w, 'walker-phone-18', pg_temp.item('health_store', 5000, pg_temp.hrs(8, 3000, 10, 2000)));
  assert r -> 0 ->> 'status' = 'ok', r::text;
  -- new app: only steps since the reset = 0 so far
  r := public.ingest_steps(w, 'walker-phone-18', pg_temp.item('health_store', 0, pg_temp.hrs(8, 0), cf));
  assert r -> 0 ->> 'status' = 'ok', r::text;
  assert (select steps from public.step_days where profile_id = w and local_date = pg_temp.today()::date) = 0,
    'the walker''s own day total is zero: fresh start';
  -- they walk 250 steps
  r := public.ingest_steps(w, 'walker-phone-18', pg_temp.item('health_store', 250, pg_temp.hrs(12, 250), cf));
  assert (select steps from public.step_days where profile_id = w and local_date = pg_temp.today()::date) = 250;
end $$;
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000001', false) \gset
do $$
begin
  assert (public.event_board('a8a8a8a8-eeee-0000-0000-000000000001', 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null) ->> 'total_steps')::int = 250,
    'the board counts exactly the fresh steps (no second subtraction)';
end $$;

-- ---------- the phone sensor, which normally never goes down, also restarts ----------
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000003', false) \gset
do $$
declare p uuid := current_setting('t.pl')::uuid; r jsonb;
begin
  r := public.ingest_steps(p, 'plain-phone-18', pg_temp.item('phone_sensor', 4000, pg_temp.hrs(9, 4000)));
  assert r -> 0 ->> 'status' = 'ok', r::text;
  r := public.ingest_steps(p, 'plain-phone-18', pg_temp.item('phone_sensor', 30, pg_temp.hrs(12, 30)));
  assert (select steps from public.step_days where profile_id = p) = 4000, 'without a reset the sensor never goes down';
end $$;
reset role;
update public.profiles set count_from = now() where id = current_setting('t.pl')::uuid;
set role authenticated;
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000003', false) \gset
do $$
declare p uuid := current_setting('t.pl')::uuid; r jsonb; cf timestamptz;
begin
  select count_from into cf from public.profiles where id = p;
  r := public.ingest_steps(p, 'plain-phone-18', pg_temp.item('phone_sensor', 30, pg_temp.hrs(12, 30), cf));
  assert (select steps from public.step_days where profile_id = p) = 30, 'with a reset it restarts';
  r := public.ingest_steps(p, 'plain-phone-18', pg_temp.item('phone_sensor', 90, pg_temp.hrs(12, 90), cf));
  assert (select steps from public.step_days where profile_id = p) = 90;
  -- a member cannot move their own count_from
  begin update public.profiles set count_from = null where id = p; assert false, 'must not be updatable';
  exception when insufficient_privilege then null; end;
end $$;

-- ---------- undo: the phone uploads the full day again and everything is back ----------
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000001', false) \gset
do $$ begin
  assert public.admin_undo_reset('a8a8a8a8-eeee-0000-0000-000000000001', null) = 1;
end $$;
reset role;
do $$ begin
  assert (select count_from from public.profiles where id = current_setting('t.w')::uuid) is null, 'count_from cleared on undo';
end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000002', false) \gset
do $$
declare w uuid := current_setting('t.w')::uuid; r jsonb;
begin
  r := public.ingest_steps(w, 'walker-phone-18', pg_temp.item('health_store', 5250, pg_temp.hrs(8, 3000, 10, 2000, 12, 250)));
  assert (select steps from public.step_days where profile_id = w and local_date = pg_temp.today()::date) = 5250;
end $$;
select set_config('request.jwt.claim.sub', 'a8a8a8a8-0000-0000-0000-000000000001', false) \gset
do $$ begin
  assert (public.event_board('a8a8a8a8-eeee-0000-0000-000000000001', 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null) ->> 'total_steps')::int = 5250;
end $$;
reset role;
\echo ALL FRESH START TESTS PASSED
