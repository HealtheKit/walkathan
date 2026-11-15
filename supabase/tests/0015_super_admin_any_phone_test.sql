\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('f5f5f5f5-0000-0000-0000-000000000001', 'super15@example.com', now()),
  ('f5f5f5f5-0000-0000-0000-000000000002', 'mem15@example.com', now());
insert into public.platform_admins (user_id) values ('f5f5f5f5-0000-0000-0000-000000000001') on conflict do nothing;

set role authenticated;
select set_config('request.jwt.claim.sub', 'f5f5f5f5-0000-0000-0000-000000000001', false) \gset
do $$
begin
  assert public.register_login_device('super-phone-1501', 'Android phone') ->> 'status' = 'approved';
  -- a second and third phone: still no approval
  assert public.register_login_device('super-phone-1502', 'iPhone') ->> 'status' = 'approved', 'any phone';
  assert public.register_login_device('super-phone-1503', null) ->> 'status' = 'approved';
  assert not exists (select 1 from jsonb_array_elements(public.review_device_requests(null)) x
                      where x ->> 'account_id' = 'f5f5f5f5-0000-0000-0000-000000000001'),
    'super admin phones are never listed for approval';
end $$;

-- a normal member is unaffected: a second phone still waits
select set_config('request.jwt.claim.sub', 'f5f5f5f5-0000-0000-0000-000000000002', false) \gset
do $$
begin
  assert public.register_login_device('mem-phone-1501', null) ->> 'status' = 'approved';
  assert public.register_login_device('mem-phone-1502', null) ->> 'status' = 'pending';
end $$;
reset role;

-- a phone that was pending BEFORE the login became Super Admin is released
insert into auth.users (id, email, email_confirmed_at) values ('f5f5f5f5-0000-0000-0000-000000000003', 'later15@example.com', now());
insert into public.account_devices (account_id, device_id, status, auto_reason) values
  ('f5f5f5f5-0000-0000-0000-000000000003', 'old-phone-1503', 'approved', 'first_device');
insert into public.account_devices (account_id, device_id, status) values
  ('f5f5f5f5-0000-0000-0000-000000000003', 'new-phone-1503', 'pending');
insert into public.platform_admins (user_id) values ('f5f5f5f5-0000-0000-0000-000000000003') on conflict do nothing;
set role authenticated;
select set_config('request.jwt.claim.sub', 'f5f5f5f5-0000-0000-0000-000000000003', false) \gset
do $$
begin
  assert public.register_login_device('new-phone-1503', null) ->> 'status' = 'approved', 'pending phone released';
end $$;
reset role;
\echo ALL SUPER ADMIN PHONE TESTS PASSED
