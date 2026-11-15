\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('d3d3d3d3-0000-0000-0000-000000000001', 'super13@example.com', now()),
  ('d3d3d3d3-0000-0000-0000-000000000002', 'org13@example.com', now()),
  ('d3d3d3d3-0000-0000-0000-000000000003', 'other13@example.com', now()),
  ('d3d3d3d3-0000-0000-0000-000000000004', 'mem13@example.com', now()),
  ('d3d3d3d3-0000-0000-0000-000000000005', 'orgmem13@example.com', now());
insert into public.platform_admins (user_id) values ('d3d3d3d3-0000-0000-0000-000000000001') on conflict do nothing;
insert into public.events (id, name, starts_on, ends_on) values
  ('d3d3d3d3-eeee-0000-0000-000000000001', 'E1', current_date, current_date + 5),
  ('d3d3d3d3-eeee-0000-0000-000000000002', 'E2', current_date, current_date + 5);
insert into public.event_accounts (event_id, account_id) values
  ('d3d3d3d3-eeee-0000-0000-000000000001', 'd3d3d3d3-0000-0000-0000-000000000004'),
  ('d3d3d3d3-eeee-0000-0000-000000000001', 'd3d3d3d3-0000-0000-0000-000000000005');
insert into public.event_organizers (event_id, user_id) values
  ('d3d3d3d3-eeee-0000-0000-000000000001', 'd3d3d3d3-0000-0000-0000-000000000002'),
  ('d3d3d3d3-eeee-0000-0000-000000000001', 'd3d3d3d3-0000-0000-0000-000000000005'),
  ('d3d3d3d3-eeee-0000-0000-000000000002', 'd3d3d3d3-0000-0000-0000-000000000003');

set role authenticated;
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000004', false) \gset
do $$
declare r jsonb; me uuid; days jsonb;
begin
  -- first phone: straight in
  r := public.register_login_device('old-phone-1301', 'Android phone');
  assert r ->> 'status' = 'approved', 'first phone is approved: ' || r::text;
  -- the old phone again: straight in
  assert public.register_login_device('old-phone-1301', 'Android phone') ->> 'status' = 'approved';
  -- a new phone waits
  r := public.register_login_device('new-phone-1302', 'iPhone');
  assert r ->> 'status' = 'pending', 'new phone is pending';
  assert public.register_login_device('new-phone-1302', 'iPhone') ->> 'status' = 'pending', 'still pending';
  begin perform public.register_login_device('short', null); assert false;
  exception when invalid_parameter_value then null; end;
  -- a member cannot review
  begin perform public.review_device_requests(); assert false;
  exception when insufficient_privilege then null; end;
  begin perform public.decide_device('d3d3d3d3-0000-0000-0000-000000000004', 'new-phone-1302', true); assert false;
  exception when insufficient_privilege then null; end;
end $$;

-- uploads: the old phone works, the pending phone is refused
select id as me from public.profiles where account_id = 'd3d3d3d3-0000-0000-0000-000000000004' and relation = 'self' \gset
reset role;
select set_config('t.me', :'me', false) \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000004', false) \gset
do $$
declare
  me uuid := current_setting('t.me')::uuid;
  d text := ((now() at time zone 'UTC')::date - 1)::text;
  r jsonb;
begin
  r := public.ingest_steps(me, 'old-phone-1301', jsonb_build_array(
         jsonb_build_object('local_date', d, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 3000)));
  assert r -> 0 ->> 'status' = 'ok', 'old phone uploads: ' || r::text;
  r := public.ingest_steps(me, 'new-phone-1302', jsonb_build_array(
         jsonb_build_object('local_date', d, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 3500)));
  assert r -> 0 ->> 'reason' = 'device_not_approved', 'pending phone refused: ' || r::text;
end $$;

-- an organizer of ANOTHER event sees nothing and cannot approve
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000003', false) \gset
do $$
begin
  assert jsonb_array_length(public.review_device_requests()) = 0;
  assert public.pending_approval_count() = 0;
  begin
    perform public.decide_device('d3d3d3d3-0000-0000-0000-000000000004', 'new-phone-1302', true);
    assert false, 'outsider must not decide';
  exception when insufficient_privilege then null; end;
end $$;

-- the member's own organizer for E1 sees it and rejects once, then member retries, then approves
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000002', false) \gset
do $$
declare v jsonb;
begin
  v := public.review_device_requests();
  assert jsonb_array_length(v) = 1 and public.pending_approval_count() = 1, 'organizer sees the request';
  assert v -> 0 ->> 'email' = 'mem13@example.com' and (v -> 0 ->> 'other_phones')::int = 1;
  assert public.decide_device('d3d3d3d3-0000-0000-0000-000000000004', 'new-phone-1302', false, 'who are you') = 'rejected';
  assert public.decide_device('d3d3d3d3-0000-0000-0000-000000000004', 'new-phone-1302', true) = 'already_rejected';
end $$;
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000004', false) \gset
do $$
declare r jsonb;
begin
  r := public.register_login_device('new-phone-1302', null);
  assert r ->> 'status' = 'rejected' and r ->> 'note' = 'who are you', 'rejection shown: ' || r::text;
  assert public.register_login_device('new-phone-1302', null, true) ->> 'status' = 'pending', 'ask again';
end $$;
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000002', false) \gset
do $$
begin
  assert public.decide_device('d3d3d3d3-0000-0000-0000-000000000004', 'new-phone-1302', true, 'ok') = 'approved';
end $$;
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000004', false) \gset
do $$
declare
  me uuid := current_setting('t.me')::uuid;
  r jsonb;
begin
  assert public.register_login_device('new-phone-1302', null) ->> 'status' = 'approved', 'now logs straight in';
  r := public.ingest_steps(me, 'new-phone-1302', jsonb_build_array(
         jsonb_build_object('local_date', ((now() at time zone 'UTC')::date - 2)::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 2500)));
  assert r -> 0 ->> 'status' = 'ok', 'approved phone uploads (device binding rules still apply): ' || r::text;
end $$;

-- an organizer who is also the member cannot approve their own phone; Super Admin can
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000005', false) \gset
do $$
begin
  assert public.register_login_device('org-phone-1303', null) ->> 'status' = 'approved';
  assert public.register_login_device('org-phone-1304', null) ->> 'status' = 'pending';
  begin perform public.decide_device('d3d3d3d3-0000-0000-0000-000000000005', 'org-phone-1304', true); assert false;
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub', 'd3d3d3d3-0000-0000-0000-000000000001', false) \gset
do $$
begin
  assert public.decide_device('d3d3d3d3-0000-0000-0000-000000000005', 'org-phone-1304', true) = 'approved';
end $$;
reset role;

-- accounts that already uploaded before this migration are "old phone" users
do $$ begin
  assert exists (select 1 from public.account_devices where auto_reason = 'first_device');
end $$;
\echo ALL DEVICE LOGIN TESTS PASSED
