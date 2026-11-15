-- Behaviour and authorization tests for 0003_steps.
\set ON_ERROR_STOP on
\set a  '66666666-6666-6666-6666-666666666666'
\set b  '77777777-7777-7777-7777-777777777777'

insert into auth.users (id, email, email_confirmed_at) values
  (:'a', 'steps-a@example.com', now()), (:'b', 'steps-b@example.com', now());
-- A: self + spouse. B: self.
insert into public.profiles (id, account_id, relation, display_name)
  select '66666666-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'a', 'spouse', 'Spouse A';

\set pa  '(select id from public.profiles where account_id = ''66666666-6666-6666-6666-666666666666'' and relation = ''self'')'
\set pa2 '66666666-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
\set pb  '(select id from public.profiles where account_id = ''77777777-7777-7777-7777-777777777777'')'

-- helper: a day item for "N days ago" in UTC
create function pg_temp.item(p_days_ago int, p_src text, p_steps int, p_off int default 0,
                             p_obs timestamptz default now())
returns jsonb language sql as $$
  select jsonb_build_object('observed_at', p_obs,
    'local_date', ((((now() at time zone 'UTC') + make_interval(mins => p_off))::date) - p_days_ago)::text,
    'tz_offset_min', p_off, 'source', p_src, 'steps', p_steps, 'distance_m', p_steps * 7 / 10, 'kcal', p_steps / 25)
$$;

set role authenticated;
select set_config('request.jwt.claim.sub', :'a', false) \gset

do $$
declare
  pa uuid := (select id from public.profiles where account_id = '66666666-6666-6666-6666-666666666666' and relation = 'self');
  r jsonb; n int;
begin
  -- 1. basic ingest creates the day and the day/week totals
  r := public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(3, 'health_store', 4000)));
  assert r -> 0 ->> 'status' = 'ok', 'basic ingest ok: ' || r::text;
  assert (select steps from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 3) = 4000;
  assert (select count(*) from public.period_totals where profile_id = pa) = 2, 'one day row + one week row';

  -- 2. idempotent: resending the same total changes nothing
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(3, 'health_store', 4000)));
  assert (select steps from public.period_totals where profile_id = pa and period = 'week'
          and period_key = date_trunc('week', (now() at time zone 'UTC')::date - 3)::date::text) = 4000, 'no double count on resend';

  -- 3. health store: a NEWER, lower reading corrects downward (e.g. a bike
  --    session logged later), but an OLDER reading cannot overwrite it.
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(3, 'health_store', 1500, 0, now() + interval '1 minute')));
  assert (select steps from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 3) = 1500, 'newer lower health reading corrects downward';
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(3, 'health_store', 9000, 0, now() - interval '1 hour')));
  assert (select steps from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 3) = 1500, 'older health reading ignored';

  -- 4. sources are never summed, and the health store is authoritative: a
  --    higher raw phone-sensor total must NOT override it (the sensor cannot
  --    know about bike sessions).
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(3, 'phone_sensor', 5200)));
  assert (select steps from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 3) = 1500, 'health store beats a higher sensor total';
  assert (select source from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 3) = 'health_store';
  -- sensor alone (no health data that day): used, and never goes down
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(5, 'phone_sensor', 3000)));
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(5, 'phone_sensor', 2000)));
  assert (select steps from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 5) = 3000, 'sensor-only day uses the sensor and never goes down';
  assert (select source from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 5) = 'phone_sensor';
  -- health data arriving later takes over the day entirely
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(5, 'health_store', 1200)));
  assert (select steps from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 5) = 1200, 'health store takes over from the sensor';
  -- a future observed_at cannot be used to win ordering forever
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(5, 'health_store', 7777, 0, now() + interval '30 days')));
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(5, 'health_store', 1300, 0, now() + interval '10 minutes')));
  assert (select steps from public.step_days where profile_id = pa and local_date = (now() at time zone 'UTC')::date - 5) = 1300, 'far-future observed_at is clamped';

  -- 5. weekly total = sum of days in the same week; other week separate
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(2, 'health_store', 1000)));
  assert (select steps from public.period_totals where profile_id = pa and period = 'day'
          and period_key = ((now() at time zone 'UTC')::date - 2)::text) = 1000;
  assert (select coalesce(sum(steps), 0) from public.step_days where profile_id = pa
            and date_trunc('week', local_date) = date_trunc('week', (now() at time zone 'UTC')::date - 3))
       = (select steps from public.period_totals where profile_id = pa and period = 'week'
            and period_key = date_trunc('week', (now() at time zone 'UTC')::date - 3)::date::text), 'week total equals sum of its days';
  perform public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(pg_temp.item(20, 'health_store', 777)));
  assert (select count(distinct period_key) from public.period_totals where profile_id = pa and period = 'week') >= 2, 'a different week gets its own total';

  -- 6. validation
  r := public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(
    pg_temp.item(-1, 'health_store', 100),            -- future
    pg_temp.item(40, 'health_store', 100),            -- too old
    pg_temp.item(5, 'health_store', 100001),          -- out of range
    pg_temp.item(5, 'bogus', 100),                    -- bad source
    pg_temp.item(5, 'health_store', -5),              -- negative
    jsonb_build_object('local_date', 'not-a-date', 'tz_offset_min', 0, 'source', 'health_store', 'steps', 1),
    jsonb_build_object('local_date', (now() at time zone 'UTC')::date::text, 'tz_offset_min', 5000, 'source', 'health_store', 'steps', 1)));
  assert r -> 0 ->> 'reason' = 'future_date', r::text;
  assert r -> 1 ->> 'reason' = 'too_old';
  assert r -> 2 ->> 'reason' = 'steps_out_of_range';
  assert r -> 3 ->> 'reason' = 'bad_source';
  assert r -> 4 ->> 'reason' = 'steps_out_of_range';
  assert r -> 5 ->> 'reason' = 'malformed';
  assert r -> 6 ->> 'reason' = 'malformed', 'absurd UTC offset rejected';
  assert (select count(*) from public.step_days where profile_id = pa) = 4, 'rejected items stored nothing';

  -- 7. implausible rate today: pick the offset whose local day just started
  declare o int; e numeric; best_o int; best_e numeric := 1e12; ln timestamp;
  begin
    for o in select generate_series(-720, 840, 60) loop
      ln := (now() at time zone 'UTC') + make_interval(mins => o);
      e := extract(epoch from (ln - ln::date::timestamp));
      if e < best_e then best_e := e; best_o := o; end if;
    end loop;
    ln := (now() at time zone 'UTC') + make_interval(mins => best_o);
    r := public.ingest_steps(pa, 'device-aaaa-1', jsonb_build_array(jsonb_build_object(
      'local_date', ln::date::text, 'tz_offset_min', best_o, 'source', 'phone_sensor',
      'steps', (best_e * 4 + 5000)::int)));
    assert r -> 0 ->> 'reason' = 'implausible_rate', 'cap on steps per second: ' || r::text;
  end;

  -- 8. one phone -> one profile, always (spouse on the same phone)
  r := public.ingest_steps('66666666-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'device-aaaa-1',
        jsonb_build_array(pg_temp.item(3, 'health_store', 2000)));
  assert r -> 0 ->> 'reason' = 'device_in_use', 'same device, same day, other profile: ' || r::text;
  r := public.ingest_steps('66666666-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'device-aaaa-2',
        jsonb_build_array(pg_temp.item(3, 'health_store', 2000)));
  assert r -> 0 ->> 'status' = 'ok', 'spouse on their own device is fine';
  r := public.ingest_steps('66666666-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'device-aaaa-1',
        jsonb_build_array(pg_temp.item(9, 'health_store', 2000)));
  assert r -> 0 ->> 'reason' = 'device_in_use', 'a phone stays with its profile on other days too';

  -- 9. clients cannot write the tables directly
  begin
    insert into public.step_days (profile_id, local_date, steps, source, tz) values (pa, current_date, 99999, 'health_store', 'UTC');
    assert false, 'direct insert into step_days must be denied';
  exception when insufficient_privilege then null; end;
  begin
    update public.step_days set steps = 99999 where profile_id = pa;
    assert false, 'direct update must be denied';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.step_day_sources;
    assert false, 'sources table not readable';
  exception when insufficient_privilege then null; end;
  begin
    perform public.recompute_step_day(pa, current_date);
    assert false, 'internal functions not callable';
  exception when insufficient_privilege then null; end;
end $$;

-- ---------- account B: isolation ----------
select set_config('request.jwt.claim.sub', :'b', false) \gset
do $$
declare
  pa uuid := (select id from public.profiles where account_id = '66666666-6666-6666-6666-666666666666' and relation = 'self');
  pb uuid := (select id from public.profiles where account_id = '77777777-7777-7777-7777-777777777777');
  r jsonb;
begin
  assert (select count(*) from public.step_days) = 0, 'B sees none of A''s steps';
  assert (select count(*) from public.period_totals) = 0, 'B sees none of A''s totals';
  begin
    perform public.ingest_steps(pa, 'device-bbbb-1', jsonb_build_array(pg_temp.item(1, 'health_store', 10)));
    assert false, 'B cannot upload for A''s profile';
  exception when insufficient_privilege then null; end;
  begin
    perform public.ingest_steps(pb, 'x', '[]'::jsonb);
    assert false, 'short device id rejected';
  exception when invalid_parameter_value then null; end;
  r := public.ingest_steps(pb, 'device-bbbb-1', jsonb_build_array(pg_temp.item(1, 'health_store', 900)));
  assert r -> 0 ->> 'status' = 'ok', 'B can upload own';
  assert (select count(*) from public.step_days) = 1, 'B sees exactly own day';
end $$;

-- ---------- anonymous ----------
reset role; set role anon;
select set_config('request.jwt.claim.sub', '', false) \gset
do $$ begin
  begin
    perform public.ingest_steps(gen_random_uuid(), 'device-anon-1', '[]'::jsonb);
    assert false, 'anon cannot ingest';
  exception when insufficient_privilege then null; end;
  begin
    perform 1 from public.step_days;
    assert false, 'anon cannot read';
  exception when insufficient_privilege then null; end;
end $$;

-- ---------- profile deletion cascades ----------
reset role;
do $$ begin
  delete from auth.users where id = '77777777-7777-7777-7777-777777777777';
  assert (select count(*) from public.step_days where profile_id not in (select id from public.profiles)) = 0, 'no orphan days';
  assert (select count(*) from public.period_totals where profile_id not in (select id from public.profiles)) = 0, 'no orphan totals';
  assert (select count(*) from public.step_day_sources where profile_id not in (select id from public.profiles)) = 0, 'no orphan sources';
end $$;

\echo 'ALL STEP TESTS PASSED'
