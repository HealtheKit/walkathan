-- Authorization tests for 0001_foundation (household model).
-- Run against a scratch database with stand-in auth objects
-- (see supabase/tests/run_local.sh). A failed ASSERT aborts non-zero.
\set ON_ERROR_STOP on
\set a '11111111-1111-1111-1111-111111111111'
\set b '22222222-2222-2222-2222-222222222222'
\set c '33333333-3333-3333-3333-333333333333'

insert into public.platform_admin_emails values ('boss@example.com');
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data) values
  (:'a', 'a@example.com', now(), '{"name":"Alice"}'),
  (:'b', 'b@example.com', now(), '{"full_name":"Bob","locale":"ta"}'),
  (:'c', 'boss@example.com', null, '{}');

do $$ begin
  assert (select count(*) from public.profiles) = 3, 'signup creates one profile per account';
  assert (select count(*) from public.profiles where relation = 'self') = 3, 'it is the self profile';
  assert (select display_name from public.profiles where account_id = '11111111-1111-1111-1111-111111111111') = 'Alice', 'name from metadata';
  assert (select display_name from public.profiles where account_id = '22222222-2222-2222-2222-222222222222') = 'Bob', 'full_name fallback';
  assert (select locale from public.profiles where account_id = '22222222-2222-2222-2222-222222222222') = 'ta', 'locale from metadata';
  assert (select count(*) from public.platform_admins) = 0, 'unverified seeded email is NOT promoted';
end $$;

update auth.users set email_confirmed_at = now() where id = :'c';
do $$ begin
  assert (select count(*) from public.platform_admins
          where user_id = '33333333-3333-3333-3333-333333333333') = 1, 'verified seeded email IS promoted';
end $$;

-- ---------- as account A ----------
set role authenticated;
select set_config('request.jwt.claim.sub', :'a', false) \gset

do $$
declare n int;
begin
  assert (select count(*) from public.profiles) = 1, 'A sees only own account profiles';

  update public.profiles set display_name = 'Hacked'
   where account_id = '22222222-2222-2222-2222-222222222222';
  get diagnostics n = row_count;
  assert n = 0, 'A cannot update B''s profile';

  -- household: add spouse + 3 children + other = 6 total
  insert into public.profiles (account_id, relation, display_name) values
    (auth.uid(), 'spouse', 'Sam'), (auth.uid(), 'child', 'Kid1'),
    (auth.uid(), 'child', 'Kid2'), (auth.uid(), 'child', 'Kid3'),
    (auth.uid(), 'other', 'Gran');
  assert (select count(*) from public.profiles) = 6, 'A now has 6 profiles';

  begin
    insert into public.profiles (account_id, relation, display_name) values (auth.uid(), 'child', 'Kid4');
    assert false, 'a 7th profile must be rejected';
  exception when check_violation then null; end;

  begin
    insert into public.profiles (account_id, relation) values ('22222222-2222-2222-2222-222222222222', 'child');
    assert false, 'cannot add a profile to someone else''s account';
  exception when insufficient_privilege or check_violation then null; end;

  begin
    insert into public.profiles (account_id, relation) values (auth.uid(), 'self');
    assert false, 'clients cannot create a self profile';
  exception when insufficient_privilege or check_violation or unique_violation then null; end;

  update public.profiles set display_name = 'Alice2', daily_goal = 10000
   where account_id = auth.uid() and relation = 'self';
  get diagnostics n = row_count;
  assert n = 1, 'A can update an own profile (allowed columns)';

  begin
    update public.profiles set account_id = '22222222-2222-2222-2222-222222222222' where relation = 'spouse';
    assert false, 'account_id not client-writable';
  exception when insufficient_privilege then null; end;
  begin
    update public.profiles set relation = 'self' where relation = 'child';
    assert false, 'relation not client-writable';
  exception when insufficient_privilege then null; end;
  begin
    update public.profiles set deleted_at = now() where relation = 'spouse';
    assert false, 'deleted_at not client-writable';
  exception when insufficient_privilege then null; end;
  begin
    update public.profiles set daily_goal = 5 where relation = 'spouse';
    assert false, 'goal check constraint';
  exception when check_violation then null; end;

  delete from public.profiles where relation = 'self';
  get diagnostics n = row_count;
  assert n = 0, 'self profile cannot be deleted by the client';

  delete from public.profiles where relation = 'other';
  get diagnostics n = row_count;
  assert n = 1, 'a non-self profile can be deleted';
  assert (select count(*) from public.profiles) = 5, 'count after delete';

  begin
    perform 1 from public.platform_admin_emails;
    assert false, 'A cannot read admin emails';
  exception when insufficient_privilege then null; end;

  assert public.is_platform_admin() = false, 'is_platform_admin false for A';
  begin
    perform * from public.admin_list_members();
    assert false, 'non-admin cannot list members';
  exception when insufficient_privilege then null; end;

  insert into public.feedback (account_id, message, diagnostics) values (auth.uid(), 'hello', '{"os":"android"}');
  assert (select count(*) from public.feedback) = 0, 'A cannot read feedback, even their own';
  begin
    insert into public.feedback (account_id, message) values ('22222222-2222-2222-2222-222222222222', 'spoof');
    assert false, 'cannot send feedback as someone else';
  exception when insufficient_privilege or check_violation then null; end;
  begin
    perform 1 from public.admin_audit_log;
    assert (select count(*) from public.admin_audit_log) = 0;
  end;
end $$;

-- ---------- as the Super Admin (C) ----------
select set_config('request.jwt.claim.sub', :'c', false) \gset
do $$ begin
  assert public.is_platform_admin() = true, 'verified seeded user is Super Admin';
  assert (select count(*) from public.profiles) = 1, 'admin cannot read other accounts'' profiles';
  assert (select count(*) from public.admin_list_members()) = 3, 'admin can list all members';
  assert (select profile_count from public.admin_list_members() where email = 'a@example.com') = 5, 'with profile counts';
  assert (select is_disabled from public.admin_list_members() where email = 'a@example.com') = false, 'not disabled by default';
  assert (select count(*) from public.feedback) = 1, 'admin can read feedback';
end $$;

-- ---------- anonymous ----------
reset role;
set role anon;
select set_config('request.jwt.claim.sub', '', false) \gset
do $$ begin
  assert (select count(*) from public.app_config where key = 'reset_epoch') = 1, 'anon can read reset_epoch';
  begin
    perform 1 from public.profiles;
    assert false, 'anon cannot read profiles';
  exception when insufficient_privilege then null; end;
  begin
    perform * from public.admin_list_members();
    assert false, 'anon cannot list members';
  exception when insufficient_privilege then null; end;
end $$;

reset role;
\echo 'ALL FOUNDATION TESTS PASSED'
