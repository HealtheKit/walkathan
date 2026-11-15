\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('a6a6a6a6-0000-0000-0000-000000000001', 'super16@example.com', now()),
  ('a6a6a6a6-0000-0000-0000-000000000002', 'ahead16@example.com', now());
insert into public.platform_admins (user_id) values ('a6a6a6a6-0000-0000-0000-000000000001') on conflict do nothing;
insert into public.events (id, name, starts_on, ends_on) values
  ('a6a6a6a6-eeee-0000-0000-000000000001', 'E16', (now() at time zone 'UTC')::date - 5, (now() at time zone 'UTC')::date + 5);
insert into public.event_accounts (event_id, account_id) values
  ('a6a6a6a6-eeee-0000-0000-000000000001', 'a6a6a6a6-0000-0000-0000-000000000002');

-- a participant whose local date is already TOMORROW (UTC+1 day), with data on today and tomorrow
do $$
declare p uuid := (select id from public.profiles where account_id = 'a6a6a6a6-0000-0000-0000-000000000002');
  u date := (now() at time zone 'UTC')::date;
begin
  insert into public.step_day_sources (profile_id, local_date, source, steps, tz, observed_at) values
    (p, u - 1, 'health_store', 3000, '+13:00', now()),
    (p, u,     'health_store', 4000, '+13:00', now()),
    (p, u + 1, 'health_store', 753,  '+13:00', now());
  perform public.recompute_step_day(p, u - 1);
  perform public.recompute_step_day(p, u);
  perform public.recompute_step_day(p, u + 1);
end $$;

set role authenticated;
select set_config('request.jwt.claim.sub', 'a6a6a6a6-0000-0000-0000-000000000001', false) \gset
do $$
declare
  e uuid := 'a6a6a6a6-eeee-0000-0000-000000000001';
  u date := (now() at time zone 'UTC')::date;
  b jsonb;
begin
  -- the admin is a day BEHIND the participant (their today = u - 1)
  b := public.event_board(e, 'event', u + 1, 50, 'steps', null);
  assert (b ->> 'total_steps')::int = 7753, 'before: ' || (b ->> 'total_steps');
  assert public.admin_reset_counts(e, null, u - 1, 'new start') = 1;
  b := public.event_board(e, 'event', u + 1, 50, 'steps', null);
  assert (b ->> 'total_steps')::int = 0, 'everything recorded so far is zero: ' || (b ->> 'total_steps');
  assert (public.admin_event_overview(e, u + 1) ->> 'total_steps')::int = 0;
end $$;
reset role;

-- steps recorded AFTER the reset count again
update public.step_day_sources set steps = steps + 300
 where profile_id = (select id from public.profiles where account_id = 'a6a6a6a6-0000-0000-0000-000000000002')
   and local_date = (now() at time zone 'UTC')::date + 1;
select public.recompute_step_day((select id from public.profiles where account_id = 'a6a6a6a6-0000-0000-0000-000000000002'),
                                 (now() at time zone 'UTC')::date + 1) \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'a6a6a6a6-0000-0000-0000-000000000001', false) \gset
do $$
begin
  assert (public.event_board('a6a6a6a6-eeee-0000-0000-000000000001', 'event', (now() at time zone 'UTC')::date + 1, 50, 'steps', null) ->> 'total_steps')::int = 300,
    'only the 300 new steps count';
end $$;
reset role;
\echo ALL RESET OWN DAY TESTS PASSED
