\set ON_ERROR_STOP on
-- users: super, two organizers of event E1, an organizer of another event E2,
-- a member M on E1, and a member N who is ALSO an organizer of E1.
insert into auth.users (id, email, email_confirmed_at) values
  ('a0a0a0a0-0000-0000-0000-000000000001', 'super@example.com', now()),
  ('a0a0a0a0-0000-0000-0000-000000000002', 'org1@example.com', now()),
  ('a0a0a0a0-0000-0000-0000-000000000003', 'org2@example.com', now()),
  ('a0a0a0a0-0000-0000-0000-000000000004', 'outsider@example.com', now()),
  ('a0a0a0a0-0000-0000-0000-000000000005', 'member@example.com', now()),
  ('a0a0a0a0-0000-0000-0000-000000000006', 'orgmember@example.com', now());
insert into public.platform_admins (user_id) values ('a0a0a0a0-0000-0000-0000-000000000001') on conflict do nothing;
insert into public.events (id, name, starts_on, ends_on) values
  ('a0a0a0a0-eeee-0000-0000-000000000001', 'E1', current_date, current_date + 5),
  ('a0a0a0a0-eeee-0000-0000-000000000002', 'E2', current_date, current_date + 5);
insert into public.event_accounts (event_id, account_id) values
  ('a0a0a0a0-eeee-0000-0000-000000000001', 'a0a0a0a0-0000-0000-0000-000000000005'),
  ('a0a0a0a0-eeee-0000-0000-000000000001', 'a0a0a0a0-0000-0000-0000-000000000006');
insert into public.event_organizers (event_id, user_id) values
  ('a0a0a0a0-eeee-0000-0000-000000000001', 'a0a0a0a0-0000-0000-0000-000000000002'),
  ('a0a0a0a0-eeee-0000-0000-000000000001', 'a0a0a0a0-0000-0000-0000-000000000003'),
  ('a0a0a0a0-eeee-0000-0000-000000000001', 'a0a0a0a0-0000-0000-0000-000000000006'),
  ('a0a0a0a0-eeee-0000-0000-000000000002', 'a0a0a0a0-0000-0000-0000-000000000004');

-- member M: OLD profile = auto 'self' (old phone), NEW = an extra profile
insert into public.profiles (id, account_id, relation, display_name, height_cm) values
  ('a0a0a0a0-1111-0000-0000-000000000001', 'a0a0a0a0-0000-0000-0000-000000000005', 'other', 'New phone', null);
update public.profiles set display_name = 'Old phone', height_cm = 170
 where account_id = 'a0a0a0a0-0000-0000-0000-000000000005' and relation = 'self';
do $$
declare
  old_id uuid := (select id from public.profiles where account_id = 'a0a0a0a0-0000-0000-0000-000000000005' and relation = 'self');
  new_id uuid := 'a0a0a0a0-1111-0000-0000-000000000001';
  d date := current_date - 3;
begin
  -- old: 3 days; new: overlaps day d with a SMALLER value
  insert into public.step_day_sources (profile_id, local_date, source, steps, tz, observed_at) values
    (old_id, d, 'health_store', 9000, '+00:00', now() - interval '1 day'),
    (old_id, d - 1, 'health_store', 7000, '+00:00', now() - interval '1 day'),
    (old_id, d - 2, 'phone_sensor', 5000, '+00:00', now() - interval '1 day'),
    (new_id, d, 'health_store', 2000, '+00:00', now() - interval '1 day');
  perform public.recompute_step_day(old_id, d); perform public.recompute_step_day(old_id, d - 1);
  perform public.recompute_step_day(old_id, d - 2); perform public.recompute_step_day(new_id, d);
  insert into public.profile_devices (device_id, profile_id) values ('old-phone-0001', old_id);
  insert into public.rest_days (profile_id, local_date) values (old_id, current_date);
end $$;

-- ---------- member: request rules ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000005', false) \gset
do $$
declare
  old_id uuid := (select id from public.profiles where account_id = 'a0a0a0a0-0000-0000-0000-000000000005' and relation = 'self');
  new_id uuid := 'a0a0a0a0-1111-0000-0000-000000000001';
  rid uuid; rows jsonb;
begin
  begin perform public.request_profile_transfer(old_id, old_id, 'new-phone-0001', 'same profile'); assert false;
  exception when invalid_parameter_value then null; end;
  begin perform public.request_profile_transfer(old_id, new_id, 'new-phone-0001', 'abc'); assert false;
  exception when check_violation then null; end;  -- reason too short

  rid := public.request_profile_transfer(old_id, new_id, 'new-phone-0001', 'My old phone broke');
  begin perform public.request_profile_transfer(old_id, new_id, 'new-phone-0001', 'second try'); assert false;
  exception when check_violation then null; end;  -- one pending per old profile

  assert (select count(*) from jsonb_array_elements(public.my_profile_transfers())) = 1;
  -- a plain member cannot review or decide
  assert not public.is_transfer_reviewer(), 'member is not a reviewer';
  begin perform public.review_profile_transfers(); assert false;
  exception when insufficient_privilege then null; end;
  begin perform public.decide_profile_transfer(rid, true); assert false;
  exception when insufficient_privilege then null; end;
  -- and cannot touch the data tables directly
  begin perform count(*) from public.profile_transfer_requests; assert false;
  exception when insufficient_privilege then null; end;
  -- another account's profile is refused
  begin perform public.request_profile_transfer(old_id, gen_random_uuid(), 'new-phone-0001', 'not mine ok'); assert false;
  exception when insufficient_privilege then null; end;
end $$;

-- cancelling then re-requesting works; cancel by someone else does not
do $$
declare rid uuid := (select (j ->> 'id')::uuid from jsonb_array_elements(public.my_profile_transfers()) j limit 1);
begin
  perform public.cancel_profile_transfer(rid);
  assert (select j ->> 'status' from jsonb_array_elements(public.my_profile_transfers()) j limit 1) = 'cancelled';
  begin perform public.cancel_profile_transfer(rid); assert false; exception when no_data_found then null; end;
  perform public.request_profile_transfer(
    (select id from public.profiles where account_id = 'a0a0a0a0-0000-0000-0000-000000000005' and relation = 'self'),
    'a0a0a0a0-1111-0000-0000-000000000001', 'new-phone-0001', 'Phone broke, new one');
end $$;

-- ---------- outsider organizer (other event) sees and can do nothing ----------
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000004', false) \gset
do $$
begin
  assert public.is_transfer_reviewer(), 'organizer of E2 is a reviewer in general';
  assert jsonb_array_length(public.review_profile_transfers()) = 0, 'but sees no requests of E1 members';
  assert public.pending_transfer_count() = 0;
  assert public.decide_profile_transfer(gen_random_uuid(), true) = 'not_found';
end $$;

-- ---------- organizer 1 of E1 rejects: nothing changes ----------
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000002', false) \gset
do $$
declare v jsonb := public.review_profile_transfers(); rid uuid; old_id uuid;
begin
  assert jsonb_array_length(v) = 1 and public.pending_transfer_count() = 1, 'organizer sees the E1 member request';
  assert v -> 0 ->> 'source_name' = 'Old phone' and (v -> 0 ->> 'source_steps')::int = 21000, 'totals shown: ' || v::text;
  rid := (v -> 0 ->> 'id')::uuid;
  assert public.decide_profile_transfer(rid, false, 'need proof') = 'rejected';
  assert public.decide_profile_transfer(rid, true) = 'already_rejected', 'cannot decide twice';
end $$;
reset role;
do $$ begin
  assert exists (select 1 from public.profiles where account_id = 'a0a0a0a0-0000-0000-0000-000000000005' and display_name = 'Old phone'),
    'rejecting keeps the old profile';
end $$;
set role authenticated;

-- member asks again
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000005', false) \gset
do $$
begin
  perform public.request_profile_transfer(
    (select id from public.profiles where account_id = 'a0a0a0a0-0000-0000-0000-000000000005' and relation = 'self'),
    'a0a0a0a0-1111-0000-0000-000000000001', 'new-phone-0001', 'Here is my proof, new phone');
end $$;

-- ---------- organizer 2 (a SECOND organizer of the same event) approves ----------
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000003', false) \gset
do $$
declare
  new_id uuid := 'a0a0a0a0-1111-0000-0000-000000000001';
  rid uuid := (public.review_profile_transfers() -> 0 ->> 'id')::uuid;
  d date := current_date - 3;
begin
  assert public.decide_profile_transfer(rid, true, 'ok') = 'approved';
end $$;
reset role;
do $$
declare
  new_id uuid := 'a0a0a0a0-1111-0000-0000-000000000001';
  acct uuid := 'a0a0a0a0-0000-0000-0000-000000000005';
  d date := current_date - 3;
begin
  assert (select count(*) from public.profiles where account_id = acct) = 1, 'old profile removed';
  assert not exists (select 1 from public.profiles where display_name = 'Old phone'), 'old is gone';
  assert (select relation from public.profiles where id = new_id) = 'self', 'new profile inherits self';
  assert (select height_cm from public.profiles where id = new_id) = 170, 'empty details filled from old';
  assert (select steps from public.step_days where profile_id = new_id and local_date = d) = 9000, 'overlap keeps larger';
  assert (select sum(steps) from public.step_days where profile_id = new_id) = 21000, 'all days merged';
  assert (select profile_id from public.profile_devices where device_id = 'new-phone-0001') = new_id, 'new phone bound';
  assert not exists (select 1 from public.profile_devices where device_id = 'old-phone-0001'), 'old phone unbound';
  assert exists (select 1 from public.rest_days where profile_id = new_id and local_date = current_date), 'rest days moved';
  assert (select count(*) from public.profile_transfer_requests where status = 'approved' and source_profile_id is null) = 1,
    'history row survives the removal';
  assert exists (select 1 from public.admin_audit_log where action = 'transfer.approve');
end $$;

-- ---------- self-approval: organizer-member cannot, Super Admin can ----------
insert into public.profiles (id, account_id, relation, display_name) values
  ('a0a0a0a0-1111-0000-0000-000000000009', 'a0a0a0a0-0000-0000-0000-000000000006', 'other', 'Second');
set role authenticated;
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000006', false) \gset
do $$
declare rid uuid;
begin
  perform public.request_profile_transfer(
    (select id from public.profiles where account_id = 'a0a0a0a0-0000-0000-0000-000000000006' and relation = 'self'),
    'a0a0a0a0-1111-0000-0000-000000000009', 'new-phone-0002', 'organizer switching phone');
  rid := (public.review_profile_transfers() -> 0 ->> 'id')::uuid;
  assert (public.review_profile_transfers() -> 0 ->> 'own_request')::boolean;
  begin perform public.decide_profile_transfer(rid, true); assert false;
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000001', false) \gset
do $$
begin
  assert public.decide_profile_transfer((public.review_profile_transfers() -> 0 ->> 'id')::uuid, true) = 'approved',
    'Super Admin approves any request';
end $$;

-- ---------- organizers: add/remove authorization ----------
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000005', false) \gset
do $$
begin
  begin perform public.add_event_organizer('a0a0a0a0-eeee-0000-0000-000000000001', 'member@example.com'); assert false;
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub', 'a0a0a0a0-0000-0000-0000-000000000002', false) \gset
do $$
begin
  assert public.add_event_organizer('a0a0a0a0-eeee-0000-0000-000000000001', 'member@example.com') = 'ok', 'organizer adds another';
  assert public.add_event_organizer('a0a0a0a0-eeee-0000-0000-000000000001', 'nobody@example.com') = 'not_found';
  assert jsonb_array_length(public.list_event_organizers('a0a0a0a0-eeee-0000-0000-000000000001')) = 4;
  -- an organizer of E1 has no say over E2
  begin perform public.add_event_organizer('a0a0a0a0-eeee-0000-0000-000000000002', 'org1@example.com'); assert false;
  exception when insufficient_privilege then null; end;
end $$;
reset role;
\echo ALL PROFILE TRANSFER TESTS PASSED
