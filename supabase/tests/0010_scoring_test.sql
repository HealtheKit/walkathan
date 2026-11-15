\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('5c000000-0000-0000-0000-000000000001', 'sc-org@example.com', now(), '{"name":"Org"}'),
  ('5c000000-0000-0000-0000-000000000002', 'sc-ver@example.com', now(), '{"name":"Ver"}'),
  ('5c000000-0000-0000-0000-000000000003', 'sc-view@example.com', now(), '{"name":"View"}'),
  ('5c000000-0000-0000-0000-000000000004', 'sc-m@example.com', now(), '{"name":"Mani"}'),
  ('5c000000-0000-0000-0000-000000000005', 'sc-f@example.com', now(), '{"name":"Fatima"}'),
  ('5c000000-0000-0000-0000-000000000006', 'sc-x@example.com', now(), '{"name":"Unset"}');
update public.profiles set sex = 'male'   where account_id = '5c000000-0000-0000-0000-000000000004';
update public.profiles set sex = 'female' where account_id = '5c000000-0000-0000-0000-000000000005';
create table pg_temp.sc as
  select u.email, p.id as pid, u.id as uid from auth.users u
    join public.profiles p on p.account_id = u.id and p.relation = 'self' where u.email like 'sc-%';
grant select on pg_temp.sc to authenticated;
create function pg_temp.p(e text) returns uuid language sql as $$ select pid from pg_temp.sc where email = 'sc-' || e || '@example.com' $$;
create function pg_temp.as_(e text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', coalesce((select uid::text from pg_temp.sc where email = 'sc-' || e || '@example.com'), '33333333-3333-3333-3333-333333333333'), false) $$;
create function pg_temp.walk(e text, ago int, n int, hrs jsonb default null) returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_(e);
  return public.ingest_steps(pg_temp.p(e), 'sc-dev-' || e, jsonb_build_array(jsonb_build_object(
    'local_date', ((now() at time zone 'UTC')::date - ago)::text, 'tz_offset_min', 0,
    'source', 'health_store', 'steps', n) || coalesce(jsonb_build_object('hours', hrs), '{}'::jsonb)));
end $$;

set role authenticated;
do $$
declare
  t date := (now() at time zone 'UTC')::date;
  ev uuid; r jsonb; b jsonb; o jsonb; h jsonb;
begin
  -- ROLES: only the Super Admin (boss) assigns staff
  perform pg_temp.as_('boss');
  assert public.admin_set_staff('sc-org@example.com', 'organizer') = 'ok';
  assert public.admin_set_staff('SC-VER@example.com', 'verifier') = 'ok';
  assert public.admin_set_staff('sc-view@example.com', 'viewer') = 'ok';
  assert public.admin_set_staff('nobody@example.com', 'viewer') = 'not_found';
  assert jsonb_array_length(public.admin_list_staff()) = 3;
  perform pg_temp.as_('org');
  begin perform public.admin_set_staff('sc-m@example.com', 'viewer'); assert false; exception when insufficient_privilege then null; end;

  -- ORGANIZER creates (as draft) and configures an event
  ev := public.admin_create_event('Scored Walk', t - 6, t + 3);
  perform public.admin_update_event(ev, p_daily_cap => 20000, p_daily_target => 5000,
                                    p_reward_min_steps => 10000, p_reward_min_active_pct => 50);
  -- viewer and verifier cannot manage
  perform pg_temp.as_('view');
  begin perform public.admin_update_event(ev, p_status => 'published'); assert false; exception when insufficient_privilege then null; end;
  begin perform public.admin_create_event('x y', t, t); assert false; exception when insufficient_privilege then null; end;
  assert jsonb_array_length(public.admin_list_events()) >= 1, 'viewer can read';
  perform pg_temp.as_('ver');
  begin perform public.admin_post_announcement(ev, 'all', 'Hi there', 'x'); assert false; exception when insufficient_privilege then null; end;
  -- members cannot do any of it
  perform pg_temp.as_('m');
  begin perform public.admin_list_events(); assert false; exception when insufficient_privilege then null; end;
  begin perform public.admin_correct_day(pg_temp.p('f'), t, 'exclude', null, 'cheat'); assert false; exception when insufficient_privilege then null; end;
  perform set_config('test.ev', ev::text, false);
end $$;

reset role;
insert into public.event_accounts (event_id, account_id)
  select current_setting('test.ev')::uuid, uid from pg_temp.sc where email in ('sc-m@example.com','sc-f@example.com','sc-x@example.com');
set role authenticated;

do $$
declare
  t date := (now() at time zone 'UTC')::date;
  ev uuid := current_setting('test.ev')::uuid;
  r jsonb; b jsonb; o jsonb; d jsonb;
begin
  -- DRAFT is invisible to members
  perform pg_temp.as_('m');
  assert (select count(*) from public.events where id = ev) = 0, 'draft hidden';
  begin perform public.event_board(ev); assert false; exception when insufficient_privilege then null; end;

  perform pg_temp.as_('org');
  perform public.admin_update_event(ev, p_status => 'published');

  -- HOURLY data: valid hours stored; hours that exceed the day total are rejected
  r := pg_temp.walk('m', 2, 6000, '[0,0,0,0,0,0,0,3000,3000,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]');
  assert r -> 0 ->> 'status' = 'ok', r::text;
  r := pg_temp.walk('m', 3, 1000, '[0,0,0,0,0,0,0,3000,3000,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]');
  assert r -> 0 ->> 'reason' = 'bad_hours', 'hours cannot exceed the day: ' || r::text;
  r := pg_temp.walk('m', 3, 1000, '[1,2,3]');
  assert r -> 0 ->> 'reason' = 'bad_hours', 'need 24 hours';
  perform pg_temp.walk('m', 1, 7000, '[0,0,0,0,0,0,0,4000,3000,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]');
  perform pg_temp.walk('m', 0, 2000);
  perform pg_temp.walk('f', 2, 9000); perform pg_temp.walk('f', 1, 50000);  -- 50k > cap 20k
  perform pg_temp.walk('x', 1, 4000);

  -- BOARD: daily cap applied; men / women boards; metrics; gap; percentile
  perform pg_temp.as_('m');
  b := public.event_board(ev, 'event', t);
  assert (b ->> 'walkers')::int = 3;
  assert b -> 'rows' -> 0 ->> 'name' = 'Fatima' and (b -> 'rows' -> 0 ->> 'steps')::int = 29000, 'cap applied: ' || b::text;
  assert (b -> 'mine' -> 0 ->> 'steps')::int = 15000 and (b -> 'mine' -> 0 ->> 'gap')::int = 14000, 'gap to next rank';
  assert (b -> 'mine' -> 0 ->> 'top_pct')::int = 67;
  assert (b ->> 'average_value')::int = 16000, 'event average';
  b := public.event_board(ev, 'event', t, 50, 'steps', 'male');
  assert (b ->> 'walkers')::int = 1 and b -> 'rows' -> 0 ->> 'name' = 'Mani', 'men only';
  b := public.event_board(ev, 'event', t, 50, 'steps', 'female');
  assert (b ->> 'walkers')::int = 1 and not (b::text like '%Unset%'), 'unspecified only on overall';
  b := public.event_board(ev, 'event', t, 50, 'active_days');
  assert b -> 'rows' -> 0 ->> 'name' = 'Mani' and (b -> 'rows' -> 0 ->> 'value')::int = 3;
  b := public.event_board(ev, 'event', t, 50, 'avg');
  assert (b -> 'rows' -> 0 ->> 'value')::int = 29000 / 7;
  begin perform public.event_board(ev, 'event', t, 50, 'bogus'); assert false; exception when invalid_parameter_value then null; end;

  -- my stats: days with hours, config
  d := public.my_event_stats(pg_temp.p('m'), ev, t);
  assert jsonb_array_length(d -> 'days') = 3 and (d -> 'event' ->> 'daily_target')::int = 5000;
  assert d -> 'days' -> 0 -> 'hours' ->> 7 = '3000', d::text;
  begin perform public.my_event_stats(pg_temp.p('f'), ev, t); assert false; exception when insufficient_privilege then null; end;

  -- ORGANIZER DASHBOARD
  perform pg_temp.as_('view');
  o := public.admin_event_overview(ev, t);
  assert (o ->> 'participants')::int = 3 and (o ->> 'active_participants')::int = 3;
  assert (o ->> 'total_steps')::int = 48000 and (o ->> 'active_today')::int = 1;
  assert jsonb_array_length(o -> 'daily') = 7;
  r := (select x from jsonb_array_elements(o -> 'participants_detail') x where x ->> 'name' = 'Fatima');
  assert (r -> 'flags') ? 'high_values', 'unusually high day flagged: ' || r::text;
  assert (r ->> 'reward_eligible')::boolean = false or (r ->> 'reward_eligible')::boolean = true;
  r := (select x from jsonb_array_elements(o -> 'participants_detail') x where x ->> 'name' = 'Unset');
  assert (r ->> 'active_pct')::int = 14;

  -- CORRECTIONS: verifier excludes Fatima's 50k day; audited; flag clears; board drops
  perform pg_temp.as_('ver');
  perform public.admin_correct_day(pg_temp.p('f'), t - 1, 'exclude', null, 'phone shaken on a bus');
  perform pg_temp.as_('m');
  b := public.event_board(ev, 'event', t);
  assert b -> 'rows' -> 0 ->> 'name' = 'Mani' and (b -> 'rows' -> 1 ->> 'steps')::int = 9000, 'excluded day gone: ' || b::text;
  perform pg_temp.as_('ver');
  perform public.admin_correct_day(pg_temp.p('f'), t - 1, 'cap', 12000, 'partially valid');
  perform pg_temp.as_('view');
  r := (select x from jsonb_array_elements(public.admin_participants(ev, t)) x where x ->> 'name' = 'Fatima');
  assert (r ->> 'total_steps')::int = 21000 and not ((r -> 'flags') ? 'high_values') and (r ->> 'corrected_days')::int = 1;
  assert (public.admin_participant_days(ev, pg_temp.p('f')) -> 0 ->> 'reason') = 'partially valid';
  perform pg_temp.as_('ver');
  perform public.admin_correct_day(pg_temp.p('f'), t - 1, 'clear');
  begin perform public.admin_correct_day(pg_temp.p('f'), t - 1, 'exclude', null, 'x'); assert false, 'reason required';
  exception when check_violation then null; end;
  perform public.admin_request_resync(pg_temp.p('m'));

  -- PARTICIPANT STATUS: blocked people leave boards and lose access
  perform pg_temp.as_('org');
  perform public.admin_set_participant_status(ev, '5c000000-0000-0000-0000-000000000006', 'blocked');
  perform pg_temp.as_('x');
  begin perform public.event_board(ev); assert false, 'blocked: no access'; exception when insufficient_privilege then null; end;
  perform pg_temp.as_('m');
  assert (public.event_board(ev, 'event', t) ->> 'walkers')::int = 2;
  perform pg_temp.as_('org');
  perform public.admin_set_participant_status(ev, '5c000000-0000-0000-0000-000000000006', 'active');  -- reinstate
  perform public.admin_set_profile_sex(pg_temp.p('x'), 'female');

  -- ANNOUNCEMENTS targeted by sex; REWARDS
  perform public.admin_post_announcement(ev, 'all', 'Welcome walkers', 'Day one starts now');
  perform public.admin_post_announcement(ev, 'female', 'Women''s board', 'Keep going');
  perform public.admin_set_reward(ev, pg_temp.p('m'), 'Gold medal', 'awarded');
  perform pg_temp.as_('m');
  d := public.my_event_stats(pg_temp.p('m'), ev, t);
  assert jsonb_array_length(d -> 'announcements') = 1, 'men do not get the women''s message';
  assert d -> 'reward' ->> 'award' = 'Gold medal' and d -> 'reward' ->> 'status' = 'awarded';
  perform pg_temp.as_('f');
  assert jsonb_array_length(public.my_event_stats(pg_temp.p('f'), ev, t) -> 'announcements') = 2;
end $$;

reset role;
do $$ begin
  assert (select count(*) from public.admin_audit_log where action like 'steps.%') >= 3, 'corrections audited';
  assert (select resync_requested_at from public.profiles p join pg_temp.sc s on s.pid = p.id where s.email = 'sc-m@example.com') is not null;
end $$;
\echo 'ALL SCORING TESTS PASSED'
