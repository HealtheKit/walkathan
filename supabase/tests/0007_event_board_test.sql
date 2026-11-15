\set ON_ERROR_STOP on
-- Super Admin boss (3333...) creates an event running now.
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('cccccccc-0000-0000-0000-000000000001', 'board-a@example.com', now(), '{"name":"Asha"}'),
  ('cccccccc-0000-0000-0000-000000000002', 'board-b@example.com', now(), '{"name":"Bala"}'),
  ('cccccccc-0000-0000-0000-000000000003', 'board-c@example.com', now(), '{}'),
  ('cccccccc-0000-0000-0000-000000000004', 'board-out@example.com', now(), '{"name":"Outsider"}');
insert into public.profiles (id, account_id, relation, display_name) values
  ('cccccccc-1111-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001', 'child', 'Asha Jr');

set role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false) \gset
select public.admin_create_event('Live Event',
  ((now() at time zone 'UTC')::date - 5), ((now() at time zone 'UTC')::date + 5)) as ev \gset
select public.admin_update_event(:'ev', p_status => 'published');
reset role;
insert into public.event_accounts (event_id, account_id) values
  (:'ev', 'cccccccc-0000-0000-0000-000000000001'),
  (:'ev', 'cccccccc-0000-0000-0000-000000000002'),
  (:'ev', 'cccccccc-0000-0000-0000-000000000003');

-- steps: Asha 9000 (2 days ago) + 1000 (yesterday); Asha Jr 3000; Bala 12000;
-- Bala also 50000 BEFORE the event (must not count); C nothing; outsider 99999.
create function pg_temp.up(p_uid uuid, p_profile uuid, p_dev text, p_ago int, p_steps int) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  -- resolve the self profile AFTER switching identity (RLS hides it before)
  p_profile := coalesce(p_profile, (select id from public.profiles
                                     where account_id = p_uid and relation = 'self'));
  perform public.ingest_steps(p_profile, p_dev, jsonb_build_array(jsonb_build_object(
    'local_date', ((now() at time zone 'UTC')::date - p_ago)::text, 'tz_offset_min', 0,
    'source', 'health_store', 'steps', p_steps)));
end $$;
set role authenticated;
select pg_temp.up('cccccccc-0000-0000-0000-000000000001', null, 'board-dev-a1', 2, 9000);
select pg_temp.up('cccccccc-0000-0000-0000-000000000001', null, 'board-dev-a1', 1, 1000);
select pg_temp.up('cccccccc-0000-0000-0000-000000000001', 'cccccccc-1111-0000-0000-000000000001', 'board-dev-a2', 1, 3000);
select pg_temp.up('cccccccc-0000-0000-0000-000000000002', null, 'board-dev-b1', 1, 12000);
select pg_temp.up('cccccccc-0000-0000-0000-000000000002', null, 'board-dev-b1', 9, 50000);
select pg_temp.up('cccccccc-0000-0000-0000-000000000004', null, 'board-dev-o1', 1, 99999);

-- as Asha
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000001', false) \gset
do $$
declare
  ev uuid := (select id from public.events where name = 'Live Event');
  b jsonb;
begin
  b := public.event_board(ev, 'event');
  assert (b ->> 'walkers')::int = 4, 'every profile on the roster is listed: ' || b::text;
  assert (b ->> 'active_walkers')::int = 3;
  assert (b ->> 'total_steps')::int = 25000, 'steps before the event and outsiders are excluded';
  assert b -> 'rows' -> 0 ->> 'name' = 'Bala' and (b -> 'rows' -> 0 ->> 'steps')::int = 12000 and (b -> 'rows' -> 0 ->> 'rank')::int = 1;
  assert b -> 'rows' -> 1 ->> 'name' = 'Asha' and (b -> 'rows' -> 1 ->> 'steps')::int = 10000;
  assert (b -> 'rows' -> 1 ->> 'mine')::boolean and not (b -> 'rows' -> 0 ->> 'mine')::boolean, 'own rows flagged';
  assert b -> 'rows' -> 2 ->> 'name' = 'Asha Jr', 'each household profile ranks separately';
  assert b -> 'rows' -> 3 ->> 'name' = 'Walker', 'empty name falls back';
  assert jsonb_array_length(b -> 'mine') = 2, 'both of my profiles returned';
  assert not (b::text like '%@example.com%'), 'no emails in the board';
  assert not (b::text like '%Outsider%'), 'non-members never appear';

  b := public.event_board(ev, 'day', (now() at time zone 'UTC')::date - 1);
  assert (b ->> 'total_steps')::int = 16000, 'day view counts only that day: ' || (b ->> 'total_steps');
  b := public.event_board(ev, 'day', date '2020-01-01');
  assert (b ->> 'today')::date >= (now() at time zone 'UTC')::date - 1, 'client date is clamped';

  b := public.event_board(ev, 'event', null, 2);
  assert jsonb_array_length(b -> 'rows') = 2, 'limit respected';
  assert jsonb_array_length(b -> 'mine') = 2, 'my rows still returned when outside the limit';

  begin perform public.event_board(ev, 'year'); assert false; exception when invalid_parameter_value then null; end;
end $$;

-- outsider: refused; unknown event: refused the same way
select set_config('request.jwt.claim.sub', 'cccccccc-0000-0000-0000-000000000004', false) \gset
do $$
declare ev uuid := (select id from public.events where name = 'Live Event');
begin
  begin perform public.event_board(ev); assert false, 'outsider must be refused'; exception when insufficient_privilege then null; end;
  begin perform public.event_board(gen_random_uuid()); assert false; exception when insufficient_privilege then null; end;
end $$;

-- Super Admin (not on the roster) may view
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false) \gset
do $$
declare ev uuid := (select id from public.events where name = 'Live Event'); b jsonb;
begin
  b := public.event_board(ev);
  assert (b ->> 'walkers')::int = 4 and jsonb_array_length(b -> 'mine') = 0;
end $$;
reset role; set role anon;
select set_config('request.jwt.claim.sub', '', false) \gset
do $$ begin
  begin perform public.event_board(gen_random_uuid()); assert false; exception when insufficient_privilege then null; end;
end $$;
reset role;
\echo 'ALL EVENT BOARD TESTS PASSED'
