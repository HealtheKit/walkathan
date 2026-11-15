\set ON_ERROR_STOP on
-- boss@example.com (33333333-...) was promoted to Super Admin in the 0001 test.
insert into auth.users (id, email, email_confirmed_at) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'ev-member@example.com', now()),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'ev-outsider@example.com', now());

set role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false) \gset
select public.admin_create_event('Spring Walkathon', '2027-03-01', '2027-03-31', 'First run') as ev \gset
select public.admin_create_event('Autumn Walkathon', '2027-10-01', '2027-10-15') as ev2 \gset
select public.admin_update_event(:'ev', p_status => 'published');
select public.admin_update_event(:'ev2', p_status => 'published');
do $$ begin
  assert jsonb_array_length(public.admin_list_events()) = 2, 'admin lists events (repeatable date slots)';
  begin
    perform public.admin_create_event('Bad', '2027-03-10', '2027-03-01');
    assert false, 'end before start rejected';
  exception when check_violation then null; end;
  begin
    perform public.admin_create_event('Too long', '2027-01-01', '2028-06-01');
    assert false, 'longer than a year rejected';
  exception when check_violation then null; end;
  begin
    insert into public.events (name, starts_on, ends_on) values ('direct', '2027-01-01', '2027-01-02');
    assert false, 'no direct inserts, even for admins';
  exception when insufficient_privilege then null; end;
  -- a draft event is invisible to members (checked below via the published ones)
  begin
    perform * from public.account_ids_by_emails(array['ev-member@example.com']);
    assert false, 'email lookup is service-role only';
  exception when insufficient_privilege then null; end;
end $$;

-- roster is written by the Edge Function with the service role
reset role;
set role service_role;
do $$ begin
  assert (select count(*) from public.account_ids_by_emails(array['EV-Member@Example.com', 'nobody@example.com'])) = 1,
         'lookup is case-insensitive and skips unknown emails';
end $$;
reset role;
insert into public.event_accounts (event_id, account_id)
  values (:'ev', 'aaaaaaaa-0000-0000-0000-000000000001');

set role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false) \gset
do $$ begin
  assert (select (x ->> 'member_count')::int from jsonb_array_elements(public.admin_list_events()) x where x ->> 'name' = 'Spring Walkathon') = 1;
  assert (select count(*) from public.admin_event_roster((select id from public.events where name = 'Spring Walkathon'))) = 1;
end $$;

-- member: sees only their event, no roster, no admin functions
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false) \gset
do $$ begin
  assert (select count(*) from public.events) = 1, 'member sees only events they are on';
  assert (select name from public.events) = 'Spring Walkathon';
  assert (select count(*) from public.event_accounts) = 1, 'member sees only own roster row';
  begin perform public.admin_list_events(); assert false; exception when insufficient_privilege then null; end;
  begin perform public.admin_event_roster(gen_random_uuid()); assert false; exception when insufficient_privilege then null; end;
  begin perform public.admin_create_event('x y', '2027-01-01', '2027-01-02'); assert false; exception when insufficient_privilege then null; end;
  begin perform public.admin_delete_event(gen_random_uuid()); assert false; exception when insufficient_privilege then null; end;
  begin
    insert into public.event_accounts (event_id, account_id) select id, auth.uid() from public.events;
    assert false, 'members cannot add themselves to events';
  exception when insufficient_privilege then null; end;
end $$;

-- outsider sees nothing
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false) \gset
do $$ begin
  assert (select count(*) from public.events) = 0, 'outsider sees no events';
  assert (select count(*) from public.event_accounts) = 0;
end $$;

-- admin removes a member and deletes an event (roster cascades)
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false) \gset
do $$
declare ev uuid := (select id from public.events where name = 'Spring Walkathon');
begin
  perform public.admin_remove_event_account(ev, 'aaaaaaaa-0000-0000-0000-000000000001');
  assert (select count(*) from public.admin_event_roster(ev)) = 0;
  perform public.admin_delete_event(ev);
  assert jsonb_array_length(public.admin_list_events()) = 1;
end $$;
reset role;
\echo 'ALL EVENT TESTS PASSED'
