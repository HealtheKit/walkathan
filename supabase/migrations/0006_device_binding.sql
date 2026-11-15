-- =====================================================================
-- 0006_device_binding: each profile has its OWN step count.
--
--  * A phone (device id) is bound to ONE profile. Only that profile can
--    upload steps from it. This replaces the weaker "one profile per device
--    per day" rule from 0003.
--  * The binding can move to another profile of the same household only
--    within 1 hour of being made (to fix a wrong pick) or after the phone
--    has not uploaded for 7 days (phone handed down). No daily switching.
--  * Uploads that exactly duplicate another household profile's total for
--    the same day are rejected ('mirrored').
-- The device id comes from the phone's hardware-scoped id where available,
-- so reinstalling the app does not mint a fresh identity. It is still
-- supplied by the client: this is strong friction, not cryptographic proof.
-- =====================================================================
create table if not exists public.profile_devices (
  device_id    text primary key check (char_length(device_id) between 8 and 64),
  profile_id   uuid not null references public.profiles (id) on delete cascade,
  bound_at     timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);
create index if not exists profile_devices_profile_idx on public.profile_devices (profile_id);
alter table public.profile_devices enable row level security;
revoke all on public.profile_devices from anon, authenticated;

-- Who owns this phone? Binds it to p_profile_id when it is free.
create or replace function public.claim_device(p_device_id text, p_profile_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  d public.profile_devices%rowtype;
  v_same_account boolean;
  v_name text;
begin
  if auth.uid() is null or not exists (
       select 1 from public.profiles where id = p_profile_id and account_id = auth.uid()) then
    raise exception 'not your profile' using errcode = 'insufficient_privilege';
  end if;
  if p_device_id is null or char_length(p_device_id) not between 8 and 64 then
    raise exception 'invalid device id' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.profile_devices (device_id, profile_id)
  values (p_device_id, p_profile_id)
  on conflict (device_id) do nothing;
  select * into d from public.profile_devices where device_id = p_device_id;

  select p.account_id = auth.uid(), p.display_name into v_same_account, v_name
    from public.profiles p where p.id = d.profile_id;

  return jsonb_build_object(
    'mine', d.profile_id = p_profile_id,
    -- never reveal another household's profile
    'owner_profile_id', case when v_same_account then d.profile_id end,
    'owner_name', case when v_same_account then v_name end,
    'can_move', d.profile_id <> p_profile_id
                and ((v_same_account and d.bound_at > now() - interval '1 hour')
                     or d.last_used_at < now() - interval '7 days'));
end;
$$;

-- Moves the phone to p_profile_id when the rules allow it.
create or replace function public.move_device(p_device_id text, p_profile_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  d public.profile_devices%rowtype;
  v_same_account boolean;
begin
  if auth.uid() is null or not exists (
       select 1 from public.profiles where id = p_profile_id and account_id = auth.uid()) then
    raise exception 'not your profile' using errcode = 'insufficient_privilege';
  end if;
  select * into d from public.profile_devices where device_id = p_device_id for update;
  if not found then
    insert into public.profile_devices (device_id, profile_id) values (p_device_id, p_profile_id);
    return;
  end if;
  if d.profile_id = p_profile_id then return; end if;

  select p.account_id = auth.uid() into v_same_account
    from public.profiles p where p.id = d.profile_id;
  if not ((v_same_account and d.bound_at > now() - interval '1 hour')
          or d.last_used_at < now() - interval '7 days') then
    raise exception 'device locked: this phone already counts steps for another profile'
      using errcode = 'check_violation';
  end if;
  update public.profile_devices
     set profile_id = p_profile_id, bound_at = now(), last_used_at = now()
   where device_id = p_device_id;
end;
$$;

revoke all on function public.claim_device(text, uuid), public.move_device(text, uuid) from public, anon;
grant execute on function public.claim_device(text, uuid), public.move_device(text, uuid) to authenticated;

-- ---------- ingest_steps, now enforcing the binding and no mirroring ----------
create or replace function public.ingest_steps(
  p_profile_id uuid,
  p_device_id  text,
  p_days       jsonb
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_item      jsonb;
  v_results   jsonb := '[]'::jsonb;
  v_date      date;
  v_tz        text;
  v_off       int;
  v_src       text;
  v_steps     int;
  v_dist      int;
  v_kcal      int;
  v_floors    int;
  v_obs       timestamptz;
  v_local_now timestamp;
  v_today     date;
  v_reason    text;
  v_device_profile uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.profiles
                  where id = p_profile_id and account_id = auth.uid()) then
    raise exception 'not your profile' using errcode = 'insufficient_privilege';
  end if;
  if p_device_id is null or char_length(p_device_id) not between 8 and 64 then
    raise exception 'invalid device id' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(p_days) is distinct from 'array' or jsonb_array_length(p_days) > 40 then
    raise exception 'invalid batch' using errcode = 'invalid_parameter_value';
  end if;

  -- One phone feeds exactly one profile. The first profile to upload from a
  -- device owns it; any other profile is refused outright.
  insert into public.profile_devices (device_id, profile_id)
  values (p_device_id, p_profile_id)
  on conflict (device_id) do nothing;
  select profile_id into v_device_profile from public.profile_devices
   where device_id = p_device_id;
  if v_device_profile <> p_profile_id then
    return (select coalesce(jsonb_agg(jsonb_build_object(
              'local_date', x ->> 'local_date', 'status', 'rejected', 'reason', 'device_in_use')), '[]'::jsonb)
            from jsonb_array_elements(p_days) as x);
  end if;
  update public.profile_devices set last_used_at = now() where device_id = p_device_id;

  for v_item in select * from jsonb_array_elements(p_days) loop
    v_reason := null;

    begin
      v_date   := (v_item ->> 'local_date')::date;
      v_off    := (v_item ->> 'tz_offset_min')::int;
      if v_off not between -840 and 840 then
        raise exception 'bad offset';
      end if;
      v_tz     := (case when v_off < 0 then '-' else '+' end)
                  || lpad((abs(v_off) / 60)::text, 2, '0') || ':'
                  || lpad((abs(v_off) % 60)::text, 2, '0');
      v_src    := v_item ->> 'source';
      v_steps  := (v_item ->> 'steps')::int;
      v_dist   := nullif(v_item ->> 'distance_m', '')::int;
      v_kcal   := nullif(v_item ->> 'kcal', '')::int;
      v_floors := nullif(v_item ->> 'floors', '')::int;
      -- When the client read the value; never trusted into the future.
      v_obs    := least(coalesce(nullif(v_item ->> 'observed_at', '')::timestamptz, now()),
                        now() + interval '5 minutes');
      v_local_now := (now() at time zone 'UTC') + make_interval(mins => v_off);
    exception when others then
      v_reason := 'malformed';
    end;

    if v_reason is null and (v_date is null or v_steps is null or v_off is null) then
      v_reason := 'malformed';
    end if;

    if v_reason is null then
      v_today := v_local_now::date;
      if v_src not in ('health_store', 'phone_sensor') then
        v_reason := 'bad_source';
      elsif v_steps < 0 or v_steps > 100000 then
        v_reason := 'steps_out_of_range';
      elsif coalesce(v_dist, 0) not between 0 and 200000
         or coalesce(v_kcal, 0) not between 0 and 20000
         or coalesce(v_floors, 0) not between 0 and 500 then
        v_reason := 'metric_out_of_range';
      elsif v_date > v_today then
        v_reason := 'future_date';
      elsif v_date < v_today - 31 then
        v_reason := 'too_old';
      elsif v_date = v_today
        and v_steps > (extract(epoch from (v_local_now - v_today::timestamp)) * 4 + 500)::int then
        -- more than 4 steps/second since local midnight is not humanly possible
        v_reason := 'implausible_rate';
      end if;
    end if;

    -- No mirroring: two profiles of one household can never hold the very
    -- same total for a day (the tell-tale of one phone's data being reused,
    -- e.g. after reinstalling the app to get a new device id).
    if v_reason is null and v_steps >= 500 and exists (
         select 1
           from public.step_day_sources s
           join public.profiles p on p.id = s.profile_id
          where p.account_id = auth.uid()
            and s.profile_id <> p_profile_id
            and s.local_date = v_date
            and s.steps = v_steps) then
      v_reason := 'mirrored';
    end if;

    if v_reason is null then
      insert into public.step_day_sources as s
        (profile_id, local_date, source, steps, distance_m, kcal, floors, tz, observed_at, updated_at)
      values (p_profile_id, v_date, v_src, v_steps, v_dist, v_kcal, v_floors, v_tz, v_obs, now())
      on conflict (profile_id, local_date, source) do update
        set -- health_store: newest reading wins (may CORRECT downward).
            -- phone_sensor: never goes down.
            distance_m = case when (s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                              then excluded.distance_m else s.distance_m end,
            kcal       = case when (s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                              then excluded.kcal else s.kcal end,
            floors     = case when (s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                              then excluded.floors else s.floors end,
            tz         = case when (s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                              then excluded.tz else s.tz end,
            steps      = case when s.source = 'health_store'
                              then (case when excluded.observed_at >= s.observed_at
                                         then excluded.steps else s.steps end)
                              else greatest(s.steps, excluded.steps) end,
            observed_at = greatest(s.observed_at, excluded.observed_at),
            updated_at = now();

      perform public.recompute_step_day(p_profile_id, v_date);
      v_results := v_results || jsonb_build_object('local_date', v_date, 'status', 'ok');
    else
      v_results := v_results || jsonb_build_object(
        'local_date', v_item ->> 'local_date', 'status', 'rejected', 'reason', v_reason);
    end if;
  end loop;

  return v_results;
end;
$$;
revoke all on function public.ingest_steps(uuid, text, jsonb) from public, anon;
grant execute on function public.ingest_steps(uuid, text, jsonb) to authenticated;

drop table if exists public.step_device_days;
