\set ON_ERROR_STOP on
insert into auth.users (id, email, email_confirmed_at) values
  ('88888888-8888-8888-8888-888888888888', 'rest-a@example.com', now()),
  ('99999999-9999-9999-9999-999999999999', 'rest-b@example.com', now());

set role authenticated;
select set_config('request.jwt.claim.sub', '88888888-8888-8888-8888-888888888888', false) \gset
do $$
declare
  pa uuid := (select id from public.profiles where account_id = '88888888-8888-8888-8888-888888888888');
  today date := (now() at time zone 'UTC')::date;
  wk date := date_trunc('week', (now() at time zone 'UTC')::date + 7)::date; -- next Monday
  n int;
begin
  insert into public.rest_days (profile_id, local_date) values (pa, today);
  assert (select count(*) from public.rest_days) = 1, 'own rest day readable';

  begin
    insert into public.rest_days (profile_id, local_date) values (pa, today - 5);
    assert false, 'back-dating must be rejected';
  exception when check_violation then null; end;
  begin
    insert into public.rest_days (profile_id, local_date) values (pa, today + 30);
    assert false, 'far future must be rejected';
  exception when check_violation then null; end;

  -- weekly limit, tested on next week (fully inside the allowed window start)
  if wk <= today + 8 then
    insert into public.rest_days (profile_id, local_date) values (pa, wk) on conflict do nothing;
    if wk + 1 <= today + 8 then
      insert into public.rest_days (profile_id, local_date) values (pa, wk + 1) on conflict do nothing;
      if wk + 2 <= today + 8 then
        begin
          insert into public.rest_days (profile_id, local_date) values (pa, wk + 2);
          assert false, 'third rest day in a week must be rejected';
        exception when check_violation then null; end;
      end if;
    end if;
  end if;

  delete from public.rest_days where profile_id = pa and local_date = today;
  get diagnostics n = row_count;
  assert n = 1, 'own rest day removable';
  insert into public.rest_days (profile_id, local_date) values (pa, today);
end $$;

select set_config('request.jwt.claim.sub', '99999999-9999-9999-9999-999999999999', false) \gset
do $$
declare
  pa uuid := (select id from public.profiles where account_id = '88888888-8888-8888-8888-888888888888');
  n int;
begin
  assert (select count(*) from public.rest_days) = 0, 'B cannot see A''s rest days';
  begin
    insert into public.rest_days (profile_id, local_date) values (pa, (now() at time zone 'UTC')::date + 1);
    assert false, 'B cannot add a rest day for A';
  exception when insufficient_privilege or check_violation then null; end;
  delete from public.rest_days where profile_id = pa;
  get diagnostics n = row_count;
  assert n = 0, 'B cannot delete A''s rest days';
end $$;
reset role;
\echo 'ALL REST DAY TESTS PASSED'
