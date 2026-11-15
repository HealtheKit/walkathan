\set ON_ERROR_STOP on
-- users: super, an organizer of E1 (not staff), outsider organizer of E2, two members
insert into auth.users (id, email, email_confirmed_at) values
  ('b1b1b1b1-0000-0000-0000-000000000001', 'super12@example.com', now()),
  ('b1b1b1b1-0000-0000-0000-000000000002', 'org12@example.com', now()),
  ('b1b1b1b1-0000-0000-0000-000000000003', 'out12@example.com', now()),
  ('b1b1b1b1-0000-0000-0000-000000000004', 'ann12@example.com', now()),
  ('b1b1b1b1-0000-0000-0000-000000000005', 'bob12@example.com', now());
insert into public.platform_admins (user_id) values ('b1b1b1b1-0000-0000-0000-000000000001') on conflict do nothing;
insert into public.events (id, name, starts_on, ends_on) values
  ('b1b1b1b1-eeee-0000-0000-000000000001', 'E1', (now() at time zone 'UTC')::date - 6, (now() at time zone 'UTC')::date + 3),
  ('b1b1b1b1-eeee-0000-0000-000000000002', 'E2', (now() at time zone 'UTC')::date - 6, (now() at time zone 'UTC')::date + 3);
insert into public.event_accounts (event_id, account_id) values
  ('b1b1b1b1-eeee-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000004'),
  ('b1b1b1b1-eeee-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000005');
insert into public.event_organizers (event_id, user_id) values
  ('b1b1b1b1-eeee-0000-0000-000000000001', 'b1b1b1b1-0000-0000-0000-000000000002'),
  ('b1b1b1b1-eeee-0000-0000-000000000002', 'b1b1b1b1-0000-0000-0000-000000000003');

-- Ann: 4 days of data (incl. today). health_store beats a bigger sensor row on one day.
do $$
declare
  ann uuid := (select id from public.profiles where account_id = 'b1b1b1b1-0000-0000-0000-000000000004');
  bob uuid := (select id from public.profiles where account_id = 'b1b1b1b1-0000-0000-0000-000000000005');
  i int;
begin
  for i in 0..3 loop
    insert into public.step_day_sources (profile_id, local_date, source, steps, distance_m, tz, observed_at)
    values (ann, (now() at time zone 'UTC')::date - i, 'health_store', 1000 + i * 100, (1000 + i * 100) * 3 / 4, '+00:00', now());
    perform public.recompute_step_day(ann, (now() at time zone 'UTC')::date - i);
  end loop;
  -- a sensor row that is larger on day -1 must NOT win and must NOT add up
  insert into public.step_day_sources (profile_id, local_date, source, steps, tz, observed_at)
  values (ann, (now() at time zone 'UTC')::date - 1, 'phone_sensor', 9000, '+00:00', now());
  perform public.recompute_step_day(ann, (now() at time zone 'UTC')::date - 1);
  insert into public.step_day_sources (profile_id, local_date, source, steps, tz, observed_at)
  values (bob, (now() at time zone 'UTC')::date, 'health_store', 2000, '+00:00', now());
  perform public.recompute_step_day(bob, (now() at time zone 'UTC')::date);
end $$;

select id as ann from public.profiles where account_id = 'b1b1b1b1-0000-0000-0000-000000000004' \gset
select id as bob from public.profiles where account_id = 'b1b1b1b1-0000-0000-0000-000000000005' \gset

select set_config('t.ann', :'ann', false), set_config('t.bob', :'bob', false) \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'b1b1b1b1-0000-0000-0000-000000000001', false) \gset

-- ---------- the three routes agree, and equal the raw sources ----------
do $$
declare
  e uuid := 'b1b1b1b1-eeee-0000-0000-000000000001';
  o jsonb := public.admin_event_overview(e, null);
  b jsonb := public.event_board(e, 'event', null, 50, 'steps', null);
  expected int := (1000 + 1100 + 1200 + 1300) + 2000;   -- 6600; never the 9000 sensor row
begin
  assert (o ->> 'total_steps')::int = expected, 'overview total ' || (o ->> 'total_steps');
  assert (b ->> 'total_steps')::int = expected, 'board total ' || (b ->> 'total_steps');
  assert (select sum((x ->> 'total_steps')::int) from jsonb_array_elements(o -> 'participants_detail') x) = expected;
  assert (select sum((x ->> 'steps')::int) from jsonb_array_elements(o -> 'daily') x) = expected, 'daily series sums to total';
end $$;

-- ---------- validator on a clean database ----------
do $$
declare v jsonb := public.admin_validate_counts('b1b1b1b1-eeee-0000-0000-000000000001', false);
begin
  assert (v ->> 'ok')::boolean, 'clean data validates: ' || v::text;
  assert jsonb_array_length(v -> 'checks') >= 6;
end $$;

-- ---------- validator catches corruption and repairs it ----------
reset role;
update public.step_days set steps = steps + 4000 where profile_id = :'ann' and local_date = (now() at time zone 'UTC')::date;     -- inflated
update public.period_totals set steps = steps + 777 where profile_id = :'bob' and period = 'week';
set role authenticated;
select set_config('request.jwt.claim.sub', 'b1b1b1b1-0000-0000-0000-000000000001', false) \gset
do $$
declare v jsonb := public.admin_validate_counts('b1b1b1b1-eeee-0000-0000-000000000001', false);
begin
  assert not (v ->> 'ok')::boolean, 'corruption detected';
  assert (select (c ->> 'mismatches')::int from jsonb_array_elements(v -> 'checks') c where c ->> 'check' = 'daily_totals_match_sources') = 1;
  assert (select (c ->> 'mismatches')::int from jsonb_array_elements(v -> 'checks') c where c ->> 'check' = 'weekly_totals_match_days') >= 1;
  v := public.admin_validate_counts('b1b1b1b1-eeee-0000-0000-000000000001', true);
  v := public.admin_validate_counts('b1b1b1b1-eeee-0000-0000-000000000001', false);
  assert (v ->> 'ok')::boolean, 'repaired: ' || v::text;
  assert (public.event_board('b1b1b1b1-eeee-0000-0000-000000000001', 'event', null, 50, 'steps', null) ->> 'total_steps')::int = 6600;
end $$;

-- ---------- participant breakdown explains the total ----------
do $$
declare d jsonb := public.admin_participant_days('b1b1b1b1-eeee-0000-0000-000000000001', current_setting('t.ann')::uuid);
begin
  assert jsonb_array_length(d) = 4, d::text;
  assert (select sum((x ->> 'counted')::int) from jsonb_array_elements(d) x) = 4600;
  assert (select jsonb_array_length(x -> 'sources') from jsonb_array_elements(d) x
           where x ->> 'date' = ((now() at time zone 'UTC')::date - 1)::text) = 2, 'both sources visible';
  assert (select (x ->> 'counted')::int from jsonb_array_elements(d) x
           where x ->> 'date' = ((now() at time zone 'UTC')::date - 1)::text) = 1100, 'the sensor row does not count';
end $$;

-- ---------- reset: one profile ----------
do $$
declare
  e uuid := 'b1b1b1b1-eeee-0000-0000-000000000001';
  ann uuid := current_setting('t.ann')::uuid;
  bob uuid := current_setting('t.bob')::uuid;
  o jsonb;
begin
  begin perform public.admin_reset_counts(e, ann, null, ''); assert false;
  exception when invalid_parameter_value then null; end;       -- reason required
  assert public.admin_reset_counts(e, ann, null, 'wrong data') = 1;
  o := public.admin_event_overview(e, null);
  assert (select (x ->> 'total_steps')::int from jsonb_array_elements(o -> 'participants_detail') x where x ->> 'profile_id' = ann::text) = 0,
    'Ann is zero: ' || o::text;
  assert (select (x ->> 'total_steps')::int from jsonb_array_elements(o -> 'participants_detail') x where x ->> 'profile_id' = bob::text) = 2000,
    'Bob untouched';
  assert (select x ->> 'reset_on' from jsonb_array_elements(o -> 'participants_detail') x where x ->> 'profile_id' = ann::text) = (now() at time zone 'UTC')::date::text;
  -- new steps AFTER the reset count again; today's earlier steps do not
  perform 1;
end $$;
reset role;
update public.step_day_sources set steps = steps + 500 where profile_id = :'ann' and local_date = (now() at time zone 'UTC')::date;
select public.recompute_step_day(:'ann', (now() at time zone 'UTC')::date) \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'b1b1b1b1-0000-0000-0000-000000000001', false) \gset
do $$
declare
  e uuid := 'b1b1b1b1-eeee-0000-0000-000000000001';
  ann uuid := current_setting('t.ann')::uuid;
begin
  assert (public.event_board(e, 'event', null, 50, 'steps', null) ->> 'total_steps')::int = 2500, 'only steps after the reset count (Ann 500 + Bob 2000)';
  -- undo brings everything back
  assert public.admin_undo_reset(e, ann) = 1;
  assert (public.event_board(e, 'event', null, 50, 'steps', null) ->> 'total_steps')::int = 6600 + 500;
  -- reset everyone
  assert public.admin_reset_counts(e, null, null, 'fresh start') = 2;
  assert (public.event_board(e, 'event', null, 50, 'steps', null) ->> 'total_steps')::int = 0, 'everyone zero';
  assert (public.admin_event_overview(e, null) ->> 'total_distance_m')::int = 0, 'distance zero too';
  assert public.admin_undo_reset(e, null) = 2;
end $$;

-- ---------- who may reset ----------
select set_config('request.jwt.claim.sub', 'b1b1b1b1-0000-0000-0000-000000000002', false) \gset
do $$
declare
  e1 uuid := 'b1b1b1b1-eeee-0000-0000-000000000001';
  e2 uuid := 'b1b1b1b1-eeee-0000-0000-000000000002';
begin
  assert public.admin_reset_counts(e1, null, null, 'organizer reset') = 2, 'event organizer may reset their event';
  assert jsonb_array_length(public.admin_list_events()) = 1, 'sees only their event';
  begin perform public.admin_reset_counts(e2, null, null, 'not mine'); assert false;
  exception when insufficient_privilege then null; end;
  begin perform public.admin_event_overview(e2, null); assert false;
  exception when insufficient_privilege then null; end;
  begin perform public.admin_undo_reset(e2, null); assert false;
  exception when insufficient_privilege then null; end;
  assert public.admin_undo_reset(e1, null) = 2;
end $$;

select set_config('request.jwt.claim.sub', 'b1b1b1b1-0000-0000-0000-000000000004', false) \gset
do $$
begin
  begin perform public.admin_reset_counts('b1b1b1b1-eeee-0000-0000-000000000001', null, null, 'cheat'); assert false;
  exception when insufficient_privilege then null; end;
  begin perform public.admin_validate_counts(null, false); assert false;
  exception when insufficient_privilege then null; end;
  begin perform public.admin_list_events(); assert false;
  exception when insufficient_privilege then null; end;
end $$;
reset role;
\echo ALL COUNT INTEGRITY TESTS PASSED
