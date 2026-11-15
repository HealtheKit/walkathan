\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('e4e4e4e4-0000-0000-0000-000000000001', 'super14@example.com', now()),
  ('e4e4e4e4-0000-0000-0000-000000000002', 'single14@example.com', now()),
  ('e4e4e4e4-0000-0000-0000-000000000003', 'family14@example.com', now());
insert into public.platform_admins (user_id) values ('e4e4e4e4-0000-0000-0000-000000000001') on conflict do nothing;
insert into public.events (id, name, starts_on, ends_on) values
  ('e4e4e4e4-eeee-0000-0000-000000000001', 'E1', current_date, current_date + 5);
-- a family login with three profiles (self + 2)
insert into public.profiles (account_id, relation, display_name) values
  ('e4e4e4e4-0000-0000-0000-000000000003', 'spouse', 'Spouse'),
  ('e4e4e4e4-0000-0000-0000-000000000003', 'child', 'Kid');

set role authenticated;
select set_config('request.jwt.claim.sub', 'e4e4e4e4-0000-0000-0000-000000000001', false) \gset
do $$
declare e uuid := 'e4e4e4e4-eeee-0000-0000-000000000001';
begin
  assert public.add_event_organizer(e, 'family14@example.com') = 'multiple_profiles', 'a family login cannot be an organizer';
  assert public.admin_set_staff('family14@example.com', 'organizer') = 'multiple_profiles', 'nor an organizer staff role';
  assert public.admin_set_staff('family14@example.com', 'viewer') = 'ok', 'other roles are unaffected';
  assert public.add_event_organizer(e, 'single14@example.com') = 'ok', 'a one-profile login can be';
  assert public.add_event_organizer(e, 'nobody@example.com') = 'not_found';
end $$;
reset role;

-- the organizer cannot add a second profile (nor via the staff role)
do $$
begin
  begin
    insert into public.profiles (account_id, relation, display_name)
    values ('e4e4e4e4-0000-0000-0000-000000000002', 'child', 'Extra');
    assert false, 'second profile must be refused';
  exception when check_violation then null; end;
  assert (select count(*) from public.profiles where account_id = 'e4e4e4e4-0000-0000-0000-000000000002') = 1;
  -- a normal login can still add profiles
  insert into public.profiles (account_id, relation, display_name)
  values ('e4e4e4e4-0000-0000-0000-000000000003', 'other', 'Another');
end $$;
\echo ALL ORGANIZER ONE-PROFILE TESTS PASSED
