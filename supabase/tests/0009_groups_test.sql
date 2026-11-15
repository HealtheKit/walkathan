\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  ('99990000-0000-0000-0000-000000000001', 'gr-owner@example.com', now(), '{"name":"Owner"}'),
  ('99990000-0000-0000-0000-000000000002', 'gr-admin@example.com', now(), '{"name":"Adi"}'),
  ('99990000-0000-0000-0000-000000000003', 'gr-member@example.com', now(), '{"name":"Mem"}'),
  ('99990000-0000-0000-0000-000000000004', 'gr-out@example.com', now(), '{"name":"Out"}');
create table pg_temp.gids as
  select u.email, p.id as pid, u.id as uid
    from auth.users u join public.profiles p on p.account_id = u.id and p.relation = 'self'
   where u.email like 'gr-%';
grant select on pg_temp.gids to authenticated;
create function pg_temp.gp(p text) returns uuid language sql as $$ select pid from pg_temp.gids where email = 'gr-' || p || '@example.com' $$;
create function pg_temp.as_(p text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', (select uid::text from pg_temp.gids where email = 'gr-' || p || '@example.com'), false) $$;
create function pg_temp.walk(p text, p_ago int, p_steps int) returns void language plpgsql as $$
begin
  perform pg_temp.as_(p);
  perform public.ingest_steps(pg_temp.gp(p), 'gr-device-' || p, jsonb_build_array(jsonb_build_object(
    'local_date', ((now() at time zone 'UTC')::date - p_ago)::text, 'tz_offset_min', 0,
    'source', 'health_store', 'steps', p_steps)));
end $$;

set role authenticated;
select pg_temp.walk('owner', 0, 3000);  select pg_temp.walk('owner', 1, 6000);
select pg_temp.walk('admin', 0, 5000);  select pg_temp.walk('admin', 1, 1000);
select pg_temp.walk('member', 0, 4000); select pg_temp.walk('member', 2, 9000);
select pg_temp.walk('out', 0, 99000);

do $$
declare
  o uuid := pg_temp.gp('owner'); a uuid := pg_temp.gp('admin');
  m uuid := pg_temp.gp('member'); x uuid := pg_temp.gp('out');
  t date := (now() at time zone 'UTC')::date;
  g uuid; code text; code2 text; r jsonb; b jsonb; i int;
begin
  -- create: creator is the owner
  perform pg_temp.as_('owner');
  g := public.group_create(o, '  Team Alpha ');
  assert (public.my_groups(o) -> 0 ->> 'role') = 'owner' and (public.my_groups(o) -> 0 ->> 'name') = 'Team Alpha';
  begin perform public.group_create(a, 'x y'); assert false, 'cannot act as another profile';
  exception when insufficient_privilege then null; end;

  -- invites: only admins create; code shown once, formatted
  code := public.group_invite_create(o, g);
  assert code ~ '^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$', code;

  -- join with the code (case/format tolerant), then again = already_member
  perform pg_temp.as_('admin');
  assert public.group_join(a, 'NOPE-NOPE-NOPE') ->> 'status' = 'invalid';
  r := public.group_join(a, lower(replace(code, '-', ' ')));
  assert r ->> 'status' = 'joined' and (r ->> 'group_id')::uuid = g, r::text;
  assert public.group_join(a, code) ->> 'status' = 'already_member';
  perform pg_temp.as_('member');
  assert public.group_join(m, code) ->> 'status' = 'joined';

  -- members cannot do admin things
  begin perform public.group_invite_create(m, g); assert false; exception when insufficient_privilege then null; end;
  begin perform public.group_update(m, g, 'Hacked'); assert false; exception when insufficient_privilege then null; end;
  begin perform public.group_set_challenge(m, g, t, t + 5); assert false; exception when insufficient_privilege then null; end;
  begin perform public.group_export(m, g, t - 5, t); assert false; exception when insufficient_privilege then null; end;
  begin perform public.group_remove_member(m, g, a); assert false; exception when insufficient_privilege then null; end;
  begin perform public.group_set_role(m, g, a, 'admin'); assert false; exception when insufficient_privilege then null; end;
  begin perform public.group_delete(m, g); assert false; exception when insufficient_privilege then null; end;

  -- outsiders see nothing and cannot read the board or members
  perform pg_temp.as_('out');
  assert jsonb_array_length(public.my_groups(x)) = 0;
  begin perform public.group_board(x, g); assert false; exception when insufficient_privilege then null; end;
  begin perform public.group_members_list(x, g); assert false; exception when insufficient_privilege then null; end;
  begin perform 1 from public.groups; assert false, 'tables are not readable'; exception when insufficient_privilege then null; end;

  -- roles: owner promotes; admin can then manage settings
  perform pg_temp.as_('owner');
  perform public.group_set_role(o, g, a, 'admin');
  perform pg_temp.as_('admin');
  perform public.group_update(a, g, 'Team Alpha 2', false, false, null);
  assert (public.my_groups(a) -> 0 ->> 'name') = 'Team Alpha 2' and not (public.my_groups(a) -> 0 ->> 'chat_enabled')::boolean
     and not (public.my_groups(a) -> 0 ->> 'taunts_enabled')::boolean;
  begin perform public.group_remove_member(a, g, o); assert false, 'nobody removes the owner';
  exception when insufficient_privilege then null; end;
  begin perform public.group_set_role(a, g, m, 'admin'); assert false, 'only the owner changes roles';
  exception when insufficient_privilege then null; end;

  -- BOARD (members only see names + totals of the group; outsider's 99,000 never appears)
  perform pg_temp.as_('member');
  b := public.group_board(m, g, 'day', t);
  assert (b -> 'group' ->> 'member_count')::int = 3;
  assert b -> 'rows' -> 0 ->> 'name' = 'Adi' and (b -> 'rows' -> 0 ->> 'steps')::int = 5000, b::text;
  assert (b -> 'rows' -> 1 ->> 'mine')::boolean and (b -> 'rows' -> 1 ->> 'steps')::int = 4000;
  assert not (b::text like '%99000%') and not (b::text like '%@example.com%');
  b := public.group_board(m, g, 'week', t);
  assert (b ->> 'excludes_today')::boolean = false;
  begin perform public.group_board(m, g, 'challenge', t); assert false, 'no challenge yet';
  exception when invalid_parameter_value then null; end;

  -- MYSTERY MODE: only admins toggle it
  begin perform public.group_update(m, g, null, null, null, true); assert false;
  exception when insufficient_privilege then null; end;
  perform pg_temp.as_('admin');
  perform public.group_update(a, g, null, null, null, true);
  perform pg_temp.as_('member');
  b := public.group_board(m, g, 'day', t);
  assert (b ->> 'steps_hidden')::boolean, 'today is hidden';
  assert (b -> 'rows' -> 0 ->> 'rank')::int = 1 and b -> 'rows' -> 0 ->> 'name' = 'Adi', 'ranks still shown';
  assert b -> 'rows' -> 0 ->> 'steps' is null, 'other people''s counts are withheld';
  assert (b -> 'rows' -> 1 ->> 'steps')::int = 4000, 'my own count is still mine to see';
  assert not (b::text like '%5000%') and not (b::text like '%3000%'), 'hidden counts are not in the payload at all';
  -- longer periods stop at yesterday so today cannot be worked out
  b := public.group_board(m, g, 'month', t);
  assert (b ->> 'excludes_today')::boolean and (b ->> 'to')::date = t - 1;
  -- BYPASS ATTEMPT: claiming tomorrow's date must not unlock today's counts
  b := public.group_board(m, g, 'month', t + 1);
  assert (b ->> 'to')::date <= t - 1, 'claimed date cannot move the mystery boundary: ' || (b ->> 'to');
  b := public.group_board(m, g, 'week', t + 1);
  assert (b ->> 'to')::date <= t - 1;
  b := public.group_board(m, g, 'day', t + 1);
  assert (b ->> 'steps_hidden')::boolean, 'a later claimed day is hidden too';
  -- yesterday (on the group's clock) is fully revealed
  b := public.group_board(m, g, 'day', t - 1);
  assert not (b ->> 'steps_hidden')::boolean, 'yesterday is revealed';
  assert (b -> 'rows' -> 0 ->> 'steps') is not null;
  -- the export cannot leak today either
  perform pg_temp.as_('admin');
  assert (public.group_export(a, g, t - 3, t + 1) ->> 'to')::date = t - 1, 'export stops at yesterday in Mystery Mode';
  perform pg_temp.as_('member');

  -- CHALLENGE: admin sets it; 1..366 days; board stays after it ends until cleared
  perform pg_temp.as_('admin');
  perform public.group_update(a, g, null, null, null, false);
  begin perform public.group_set_challenge(a, g, t, t - 1); assert false, 'end before start';
  exception when check_violation then null; end;
  begin perform public.group_set_challenge(a, g, t, t + 400); assert false, 'longer than a year';
  exception when check_violation then null; end;
  begin perform public.group_set_challenge(a, g, t, null); assert false, 'half-set challenge';
  exception when check_violation then null; end;
  perform public.group_set_challenge(a, g, t - 2, t - 1);  -- a 2-day challenge that already ended
  b := public.group_board(a, g, 'challenge', t);
  assert b -> 'rows' -> 0 ->> 'name' = 'Mem' and (b -> 'rows' -> 0 ->> 'steps')::int = 9000, 'ended challenge still readable: ' || b::text;
  assert (b -> 'rows' -> 1 ->> 'steps')::int = 6000 and (b -> 'rows' -> 2 ->> 'steps')::int = 1000;
  -- the group still works after the challenge ended
  assert (public.group_board(a, g, 'day', t) -> 'rows' -> 0 ->> 'steps')::int = 5000;
  perform public.group_set_challenge(a, g, t, t);  -- 1-day minimum is allowed
  perform public.group_set_challenge(a, g, null, null);
  begin perform public.group_board(a, g, 'challenge', t); assert false, 'cleared';
  exception when invalid_parameter_value then null; end;

  -- EXPORT: totals per member for any range; audited
  r := public.group_export(a, g, t - 6, t);
  assert jsonb_array_length(r -> 'rows') = 3 and r -> 'rows' -> 0 ->> 'name' = 'Mem'
     and (r -> 'rows' -> 0 ->> 'total_steps')::int = 13000 and (r -> 'rows' -> 0 ->> 'active_days')::int = 2, r::text;
  begin perform public.group_export(a, g, t - 500, t); assert false; exception when invalid_parameter_value then null; end;

  -- invite controls: max uses, revoke
  code2 := public.group_invite_create(a, g, 14, 1);
  perform pg_temp.as_('out');
  assert public.group_join(x, code2) ->> 'status' = 'joined', 'single-use code works once';
  perform pg_temp.as_('admin');
  perform public.group_remove_member(a, g, x);
  perform pg_temp.as_('out');
  assert public.group_join(x, code2) ->> 'status' = 'invalid', 'used-up code';
  perform pg_temp.as_('admin');
  assert public.group_invites_revoke(a, g) >= 1;
  perform pg_temp.as_('out');
  assert public.group_join(x, code) ->> 'status' = 'invalid', 'revoked code';
  -- wrong guesses are rate-limited
  for i in 1..12 loop r := public.group_join(x, 'AAAA-BBBB-' || lpad(i::text, 4, '0')); end loop;
  assert r ->> 'status' = 'rate_limited', 'guessing is throttled: ' || r::text;

  -- leaving and ownership
  perform pg_temp.as_('owner');
  begin perform public.group_leave(o, g); assert false, 'owner must hand over first';
  exception when check_violation then null; end;
  perform public.group_set_role(o, g, a, 'owner');
  r := public.group_members_list(o, g);
  assert r -> 0 ->> 'name' = 'Adi' and r -> 0 ->> 'role' = 'owner', 'ownership handed over: ' || r::text;
  assert r -> 1 ->> 'role' = 'admin' and r -> 1 ->> 'name' = 'Owner', 'old owner becomes admin';
  perform public.group_leave(o, g);
  assert jsonb_array_length(public.my_groups(o)) = 0;
  begin perform public.group_delete(o, g); assert false; exception when insufficient_privilege then null; end;

  -- new owner deletes: members and invites go with it
  perform pg_temp.as_('admin');
  perform public.group_delete(a, g);
  assert jsonb_array_length(public.my_groups(a)) = 0;
end $$;
reset role;
do $$ begin
  assert (select count(*) from public.group_members m where not exists (select 1 from public.groups g where g.id = m.group_id)) = 0;
  assert exists (select 1 from public.admin_audit_log where action = 'group.export'), 'export was audited';
end $$;
set role anon;
select set_config('request.jwt.claim.sub', '', false) \gset
do $$ begin
  begin perform public.my_groups(gen_random_uuid()); assert false; exception when insufficient_privilege then null; end;
  begin perform public.group_join(gen_random_uuid(), 'AAAA'); assert false; exception when insufficient_privilege then null; end;
end $$;
reset role;
\echo 'ALL GROUP TESTS PASSED'

