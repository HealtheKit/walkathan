\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('a7a7a7a7-0000-0000-0000-000000000001', 'super17@example.com', now()),
  ('a7a7a7a7-0000-0000-0000-000000000002', 'late17@example.com', now());
insert into public.platform_admins (user_id) values ('a7a7a7a7-0000-0000-0000-000000000001') on conflict do nothing;
insert into public.events (id, name, starts_on, ends_on) values
  ('a7a7a7a7-eeee-0000-0000-000000000001', 'E17', (now() at time zone 'UTC')::date - 5, (now() at time zone 'UTC')::date + 5);
insert into public.event_accounts (event_id, account_id) values
  ('a7a7a7a7-eeee-0000-0000-000000000001', 'a7a7a7a7-0000-0000-0000-000000000002');

-- A helper for the test: sets the day's hourly steps (and total) for the profile.
-- The profile's clock is chosen so that "now" is 12:xx local, whatever time the test runs.
create or replace function pg_temp.put_day(p_hours int[]) returns void language plpgsql as $$
declare
  p uuid := (select id from public.profiles where account_id = 'a7a7a7a7-0000-0000-0000-000000000002');
  off_h int := 12 - extract(hour from now() at time zone 'UTC')::int;       -- -11 .. +12
  tz text := (case when off_h < 0 then '-' else '+' end) || lpad(abs(off_h)::text, 2, '0') || ':00';
  d date := ((now() at time zone 'UTC') + make_interval(hours => off_h))::date;
  total int := (select sum(x) from unnest(p_hours) x);
begin
  insert into public.step_day_sources (profile_id, local_date, source, steps, tz, observed_at, hours)
  values (p, d, 'health_store', total, tz, now(), p_hours)
  on conflict (profile_id, local_date, source) do update
    set steps = excluded.steps, hours = excluded.hours, observed_at = now();
  perform public.recompute_step_day(p, d);
end $$;
create or replace function pg_temp.hrs(variadic p int[]) returns int[] language sql as $$
  -- pairs of (hour, steps)
  select array(select coalesce((select p[i + 1] from generate_subscripts(p, 1) i
                                 where i % 2 = 1 and p[i] = h), 0)
                 from generate_series(0, 23) h);
$$;

-- before the reset the server only knows 200 steps at 08:00 and 100 in the current hour (12)
select pg_temp.put_day(pg_temp.hrs(8, 200, 12, 100));

set role authenticated;
select set_config('request.jwt.claim.sub', 'a7a7a7a7-0000-0000-0000-000000000001', false) \gset
do $$
declare e uuid := 'a7a7a7a7-eeee-0000-0000-000000000001'; b jsonb;
begin
  b := public.event_board(e, 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null);
  assert (b ->> 'total_steps')::int = 300, 'before: ' || (b ->> 'total_steps');
  assert public.admin_reset_counts(e, null, null, 'restart') = 1;
  b := public.event_board(e, 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null);
  assert (b ->> 'total_steps')::int = 0, 'zero right after the reset: ' || (b ->> 'total_steps');
end $$;
reset role;

-- THE BUG: the phone now uploads steps it took BEFORE the reset (09:00-11:00) that
-- the server had never seen. They must not count.
select pg_temp.put_day(pg_temp.hrs(8, 200, 9, 3000, 10, 2000, 11, 555, 12, 100));
set role authenticated;
select set_config('request.jwt.claim.sub', 'a7a7a7a7-0000-0000-0000-000000000001', false) \gset
do $$
declare b jsonb := public.event_board('a7a7a7a7-eeee-0000-0000-000000000001', 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null);
begin
  assert (b ->> 'total_steps')::int = 0, 'late upload of earlier hours stays zero: ' || (b ->> 'total_steps');
  assert (public.admin_event_overview('a7a7a7a7-eeee-0000-0000-000000000001', (now() at time zone 'UTC')::date + 1) ->> 'total_steps')::int = 0;
end $$;
reset role;

-- walking right after the reset counts at once (same hour, above what the server had),
-- and so do later hours
select pg_temp.put_day(pg_temp.hrs(8, 200, 9, 3000, 10, 2000, 11, 555, 12, 180, 13, 400));
set role authenticated;
select set_config('request.jwt.claim.sub', 'a7a7a7a7-0000-0000-0000-000000000001', false) \gset
do $$
declare b jsonb := public.event_board('a7a7a7a7-eeee-0000-0000-000000000001', 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null);
begin
  assert (b ->> 'total_steps')::int = 80 + 400, 'new steps count: ' || (b ->> 'total_steps');
  -- undo restores everything
  assert public.admin_undo_reset('a7a7a7a7-eeee-0000-0000-000000000001', null) = 1;
  b := public.event_board('a7a7a7a7-eeee-0000-0000-000000000001', 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null);
  assert (b ->> 'total_steps')::int = 200 + 3000 + 2000 + 555 + 180 + 400;
end $$;
reset role;

do $$ begin
  assert public.tz_interval('+05:30') = interval '5 hours 30 minutes';
  assert public.tz_interval('-08:00') = interval '-8 hours';
  assert public.tz_interval('IST') is null and public.tz_interval(null) is null;
end $$;
\echo ALL RESET BY TIME TESTS PASSED
