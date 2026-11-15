\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'bind-a@example.com', now()),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'bind-b@example.com', now());
insert into public.profiles (id, account_id, relation, display_name) values
  ('bbbbbbbb-1111-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'spouse', 'Spouse'),
  ('bbbbbbbb-1111-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000001', 'child', 'Kid');

set role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000001', false) \gset
do $$
declare
  me uuid := (select id from public.profiles where account_id = 'bbbbbbbb-0000-0000-0000-000000000001' and relation = 'self');
  sp uuid := 'bbbbbbbb-1111-0000-0000-000000000001';
  kid uuid := 'bbbbbbbb-1111-0000-0000-000000000002';
  d date := (now() at time zone 'UTC')::date - 2;
  c jsonb; r jsonb;
  function_item jsonb;
begin
  -- first claim binds
  c := public.claim_device('phone-one-0001', me);
  assert (c ->> 'mine')::boolean, 'first profile owns the phone';

  -- another profile of the same household sees who owns it, and is not the owner
  c := public.claim_device('phone-one-0001', sp);
  assert not (c ->> 'mine')::boolean, 'second profile does not own it';
  assert c ->> 'owner_profile_id' = me::text, 'owner is shown within the household';
  assert (c ->> 'can_move')::boolean, 'within the 1-hour grace a wrong pick can be fixed';

  -- uploads from that phone for the spouse are refused on every day
  r := public.ingest_steps(sp, 'phone-one-0001', jsonb_build_array(
         jsonb_build_object('local_date', d::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 4321),
         jsonb_build_object('local_date', (d - 3)::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 1111)));
  assert r -> 0 ->> 'reason' = 'device_in_use' and r -> 1 ->> 'reason' = 'device_in_use', 'no sharing a phone: ' || r::text;
  assert not exists (select 1 from public.step_days where profile_id = sp), 'nothing stored for the spouse';

  -- owner uploads fine
  r := public.ingest_steps(me, 'phone-one-0001', jsonb_build_array(
         jsonb_build_object('local_date', d::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 4321)));
  assert r -> 0 ->> 'status' = 'ok';

  -- MIRRORING: the spouse on a "new" device id (e.g. app reinstalled) sending
  -- the very same total for the same day is rejected.
  r := public.ingest_steps(sp, 'phone-two-0002', jsonb_build_array(
         jsonb_build_object('local_date', d::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 4321)));
  assert r -> 0 ->> 'reason' = 'mirrored', 'identical household total rejected: ' || r::text;
  -- a genuinely different count from their own phone is fine
  r := public.ingest_steps(sp, 'phone-two-0002', jsonb_build_array(
         jsonb_build_object('local_date', d::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 3900)));
  assert r -> 0 ->> 'status' = 'ok', 'own phone, own count';
  assert (select steps from public.step_days where profile_id = sp and local_date = d) = 3900;
  assert (select steps from public.step_days where profile_id = me and local_date = d) = 4321, 'counts stay separate';
  -- tiny equal totals (e.g. both 0 or a few steps) are not treated as mirroring
  r := public.ingest_steps(sp, 'phone-two-0002', jsonb_build_array(
         jsonb_build_object('local_date', (d - 1)::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 40)));
  r := public.ingest_steps(me, 'phone-one-0001', jsonb_build_array(
         jsonb_build_object('local_date', (d - 1)::text, 'tz_offset_min', 0, 'source', 'health_store', 'steps', 40)));
  assert r -> 0 ->> 'status' = 'ok';

  -- moving within the grace hour works (wrong pick), to a household profile only
  perform public.move_device('phone-one-0001', kid);
  assert (public.claim_device('phone-one-0001', kid) ->> 'mine')::boolean, 'moved to the child';
end $$;

-- after the grace hour and with recent use, the phone is locked
reset role;
update public.profile_devices set bound_at = now() - interval '2 hours' where device_id = 'phone-one-0001';
set role authenticated;
do $$
declare me uuid := (select id from public.profiles where account_id = 'bbbbbbbb-0000-0000-0000-000000000001' and relation = 'self');
begin
  assert not (public.claim_device('phone-one-0001', me) ->> 'can_move')::boolean, 'locked after the grace hour';
  begin
    perform public.move_device('phone-one-0001', me);
    assert false, 'move must be refused while locked';
  exception when check_violation then null; end;
end $$;

-- unused for 7 days: can be handed down
reset role;
update public.profile_devices set last_used_at = now() - interval '8 days' where device_id = 'phone-one-0001';
set role authenticated;
do $$
declare me uuid := (select id from public.profiles where account_id = 'bbbbbbbb-0000-0000-0000-000000000001' and relation = 'self');
begin
  perform public.move_device('phone-one-0001', me);
  assert (public.claim_device('phone-one-0001', me) ->> 'mine')::boolean, 'handed down after 7 idle days';
end $$;

-- another household: learns nothing about the owner and cannot take the phone
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false) \gset
do $$
declare other uuid := (select id from public.profiles where account_id = 'bbbbbbbb-0000-0000-0000-000000000002');
  c jsonb;
begin
  c := public.claim_device('phone-one-0001', other);
  assert not (c ->> 'mine')::boolean;
  assert c ->> 'owner_profile_id' is null and c ->> 'owner_name' is null, 'no leak across households';
  begin
    perform public.move_device('phone-one-0001', other);
    assert false, 'cannot take a phone in active use';
  exception when check_violation then null; end;
  begin
    perform public.claim_device('phone-one-0001', 'bbbbbbbb-1111-0000-0000-000000000001');
    assert false, 'cannot claim for someone else''s profile';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.profile_devices;
    assert false, 'binding table is not readable';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
\echo 'ALL DEVICE BINDING TESTS PASSED'
