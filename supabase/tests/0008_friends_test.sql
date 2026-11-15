\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('dddddddd-0000-0000-0000-000000000001', 'fr-a@example.com', now(), '{"name":"Anu"}'),
  ('dddddddd-0000-0000-0000-000000000002', 'fr-b@example.com', now(), '{"name":"Bhanu"}'),
  ('dddddddd-0000-0000-0000-000000000003', 'fr-c@example.com', now(), '{"name":"Chitra"}');
-- shared helpers for the test: profile ids, and an "act as" switch
create table pg_temp.ids as
  select u.email, p.id as pid, u.id as uid
    from auth.users u join public.profiles p on p.account_id = u.id and p.relation = 'self'
   where u.email like 'fr-%';
grant select on pg_temp.ids to authenticated;
create function pg_temp.pid(p_email text) returns uuid language sql as
  $$ select pid from pg_temp.ids where email = p_email $$;
create function pg_temp.act(p_email text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', (select uid::text from pg_temp.ids where email = p_email), false) $$;

-- step data (as each user, on their own device)
set role authenticated;
do $$
declare d text := ((now() at time zone 'UTC')::date)::text;
begin
  perform pg_temp.act('fr-a@example.com');
  perform public.ingest_steps(pg_temp.pid('fr-a@example.com'), 'fr-device-a', jsonb_build_array(jsonb_build_object('local_date', ((now() at time zone 'UTC')::date - 1)::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 7000)));
  perform pg_temp.act('fr-b@example.com');
  perform public.ingest_steps(pg_temp.pid('fr-b@example.com'), 'fr-device-b', jsonb_build_array(jsonb_build_object('local_date', ((now() at time zone 'UTC')::date - 1)::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 9000)));
end $$;

do $$
declare
  a uuid := pg_temp.pid('fr-a@example.com');
  b uuid := pg_temp.pid('fr-b@example.com');
  c uuid := pg_temp.pid('fr-c@example.com');
  y date := (now() at time zone 'UTC')::date - 1;
  code_b text; o jsonb; brd jsonb;
begin
  -- B gets a code; A requests with it (formatting/case tolerated)
  perform pg_temp.act('fr-b@example.com');
  code_b := public.my_friend_code(b);
  assert char_length(code_b) = 8 and public.my_friend_code(b) = code_b, 'stable 8-char code';

  perform pg_temp.act('fr-a@example.com');
  assert public.friend_request(a, 'ZZZZ9999') = 'not_found', 'unknown code';
  assert public.friend_request(a, public.my_friend_code(a)) = 'not_found', 'cannot add myself';
  assert public.friend_request(a, lower(substr(code_b, 1, 4)) || '-' || substr(code_b, 5)) = 'sent';
  assert public.friend_request(a, code_b) = 'pending', 'no duplicate request';

  -- BEFORE acceptance: nothing is visible to A
  o := public.friends_overview(a, y);
  assert jsonb_array_length(o -> 'friends') = 0 and jsonb_array_length(o -> 'outgoing') = 1;
  brd := public.friend_board(a, 'day', y);
  assert jsonb_array_length(brd -> 'rows') = 1, 'board has only me before acceptance';

  begin perform public.friend_request(b, code_b); assert false, 'cannot act as another profile';
  exception when insufficient_privilege then null; end;
  begin perform public.friends_overview(b); assert false; exception when insufficient_privilege then null; end;
  begin perform public.friend_board(b); assert false; exception when insufficient_privilege then null; end;
  begin perform 1 from public.friendships; assert false, 'tables are not readable';
  exception when insufficient_privilege then null; end;

  -- B sees the request and accepts
  perform pg_temp.act('fr-b@example.com');
  o := public.friends_overview(b, y);
  assert o -> 'incoming' -> 0 ->> 'name' = 'Anu';
  perform public.friend_respond(b, a, true);

  -- now mutual, steps visible because sharing is on by default
  perform pg_temp.act('fr-a@example.com');
  o := public.friends_overview(a, y);
  assert o -> 'friends' -> 0 ->> 'name' = 'Bhanu' and (o -> 'friends' -> 0 ->> 'today_steps')::int = 9000, o::text;
  brd := public.friend_board(a, 'day', y);
  assert brd -> 'rows' -> 0 ->> 'name' = 'Bhanu' and (brd -> 'rows' -> 0 ->> 'rank')::int = 1;
  assert (brd -> 'rows' -> 1 ->> 'mine')::boolean and (brd -> 'rows' -> 1 ->> 'steps')::int = 7000;
  assert jsonb_array_length(public.friend_board(a, 'week', y) -> 'rows') = 2;
  assert jsonb_array_length(public.friend_board(a, 'month', y) -> 'rows') = 2;
  assert not (o::text like '%@example.com%'), 'no emails anywhere';

  -- B switches sharing OFF: A still has the friend, but no steps and not on the board
  perform pg_temp.act('fr-b@example.com');
  update public.profiles set steps_visibility = 'private' where id = b;
  perform pg_temp.act('fr-a@example.com');
  o := public.friends_overview(a, y);
  assert (o -> 'friends' -> 0 ->> 'sharing')::boolean = false and o -> 'friends' -> 0 ->> 'today_steps' is null, 'sharing off hides steps';
  assert jsonb_array_length(public.friend_board(a, 'day', y) -> 'rows') = 1;
  perform pg_temp.act('fr-b@example.com');
  update public.profiles set steps_visibility = 'friends' where id = b;

  -- A hides B: gone from A's board, B is unaffected and not told
  perform pg_temp.act('fr-a@example.com');
  perform public.friend_set_hidden(a, b, true);
  assert jsonb_array_length(public.friend_board(a, 'day', y) -> 'rows') = 1, 'hidden friend leaves my board';
  assert (public.friends_overview(a, y) -> 'friends' -> 0 ->> 'hidden')::boolean;
  perform pg_temp.act('fr-b@example.com');
  assert jsonb_array_length(public.friend_board(b, 'day', y) -> 'rows') = 2, 'the other side is unchanged';
  perform pg_temp.act('fr-a@example.com');
  perform public.friend_set_hidden(a, b, false);

  -- crossing requests: C asks A, then A asks C -> accepted straight away
  perform pg_temp.act('fr-a@example.com');
  declare code_a text := public.my_friend_code(a); code_c text;
  begin
    perform pg_temp.act('fr-c@example.com');
    code_c := public.my_friend_code(c);
    assert public.friend_request(c, code_a) = 'sent';
    perform pg_temp.act('fr-a@example.com');
    assert public.friend_request(a, code_c) = 'accepted', 'crossing requests accept';
    assert public.friend_request(a, code_c) = 'already_friends';

    -- remove ends it for both
    perform public.friend_remove(a, c);
    assert jsonb_array_length(public.friends_overview(a, y) -> 'friends') = 1, 'only Bhanu left';
    perform pg_temp.act('fr-c@example.com');
    assert jsonb_array_length(public.friends_overview(c, y) -> 'friends') = 0;

    -- decline removes the request
    assert public.friend_request(c, code_a) = 'sent';
    perform pg_temp.act('fr-a@example.com');
    perform public.friend_respond(a, c, false);
    assert jsonb_array_length(public.friends_overview(a, y) -> 'incoming') = 0;

    -- a requester cannot accept their own request
    perform pg_temp.act('fr-c@example.com');
    assert public.friend_request(c, code_a) = 'sent';
    perform public.friend_respond(c, a, true);
    assert jsonb_array_length(public.friends_overview(c, y) -> 'friends') = 0, 'self-accept does nothing';
    perform public.friend_remove(c, a); -- cancel my pending request

    -- BLOCK: A blocks B. Friendship ends; B cannot find or re-add A and is told nothing.
    perform pg_temp.act('fr-a@example.com');
    perform public.friend_block(a, b, true);
    assert jsonb_array_length(public.friends_overview(a, y) -> 'friends') = 0;
    assert public.friends_overview(a, y) -> 'blocked' -> 0 ->> 'name' = 'Bhanu';
    perform pg_temp.act('fr-b@example.com');
    assert jsonb_array_length(public.friends_overview(b, y) -> 'friends') = 0, 'gone for the blocked side too';
    assert public.friend_request(b, code_a) = 'not_found', 'block looks like an unknown code';
    assert jsonb_array_length(public.friend_board(b, 'day', y) -> 'rows') = 1;
    assert jsonb_array_length(public.friends_overview(b, y) -> 'blocked') = 0, 'B is not told they are blocked';
    -- unblock allows a fresh request
    perform pg_temp.act('fr-a@example.com');
    perform public.friend_block(a, b, false);
    perform pg_temp.act('fr-b@example.com');
    assert public.friend_request(b, code_a) = 'sent';

    -- direct add by profile id needs a shared event
    perform pg_temp.act('fr-c@example.com');
    assert public.friend_request(c, null, b) = 'not_found', 'no shared event: cannot add by id';
  end;
end $$;

-- put B and C on the same event, then direct add works
reset role;
insert into public.events (id, name, starts_on, ends_on)
  values ('eeeeeeee-0000-0000-0000-00000000000f', 'Friends Event', current_date, current_date + 3);
insert into public.event_accounts (event_id, account_id) values
  ('eeeeeeee-0000-0000-0000-00000000000f', 'dddddddd-0000-0000-0000-000000000002'),
  ('eeeeeeee-0000-0000-0000-00000000000f', 'dddddddd-0000-0000-0000-000000000003');
set role authenticated;
do $$ begin
  perform pg_temp.act('fr-c@example.com');
  assert public.friend_request(pg_temp.pid('fr-c@example.com'), null, pg_temp.pid('fr-b@example.com')) = 'sent',
         'same event: direct add allowed';
end $$;

-- deleting an account removes its friendships and blocks
reset role;
delete from auth.users where id = 'dddddddd-0000-0000-0000-000000000003';
do $$ begin
  assert not exists (select 1 from public.friendships f
                      where not exists (select 1 from public.profiles p where p.id = f.profile_a)
                         or not exists (select 1 from public.profiles p where p.id = f.profile_b)), 'no orphan friendships';
end $$;
set role anon;
select set_config('request.jwt.claim.sub', '', false) \gset
do $$ begin
  begin perform public.friend_board(gen_random_uuid()); assert false; exception when insufficient_privilege then null; end;
end $$;
reset role;
\echo 'ALL FRIEND TESTS PASSED'
