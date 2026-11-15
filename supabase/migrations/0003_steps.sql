-- =====================================================================
-- 0003_steps: server-side step storage and the ONLY write path for it.
--
-- Design:
--  * Clients upload DAY TOTALS per source (cumulative for a local day),
--    never individual step events. Re-sending the same data is therefore
--    idempotent, and a stale/lower upload can never reduce a total.
--  * Per day we keep one row per source (health_store | phone_sensor).
--    Sources are NEVER summed (no double counting).
--  * The health store (Apple Health / Health Connect) is AUTHORITATIVE when
--    it has data for the day: the client already removed steps recorded
--    during cycling / exercise-machine sessions, and the raw phone sensor
--    cannot know about those. The phone sensor only counts for days the
--    health store has nothing for.
--  * Health-store totals are latest-observation-wins, so a later, lower
--    (corrected) total replaces an earlier one. Sensor totals keep the
--    "never goes down" rule.
--  * No client can write these tables directly: all writes go through
--    ingest_steps(), which validates ownership and plausibility.
--  * period_totals (day/week) is maintained incrementally by a trigger so
--    leaderboards are index reads, not aggregations.
--  * "Local day" is the user's own calendar day. The client sends local_date
--    plus the device's UTC offset in minutes for that day (an offset is
--    unambiguous, unlike abbreviations such as IST, and needs no plugin).
-- =====================================================================

-- ---------- per-source day totals ----------
create table if not exists public.step_day_sources (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  local_date date not null,
  source     text not null check (source in ('health_store', 'phone_sensor')),
  steps      int  not null check (steps between 0 and 100000),
  distance_m int  check (distance_m between 0 and 200000),
  kcal       int  check (kcal between 0 and 20000),
  floors     int  check (floors between 0 and 500),
  tz         text not null,
  observed_at timestamptz not null default now(),  -- when the client read it
  updated_at timestamptz not null default now(),
  primary key (profile_id, local_date, source)
);

-- ---------- resolved day (max across sources) ----------
create table if not exists public.step_days (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  local_date date not null,
  steps      int  not null check (steps between 0 and 100000),
  distance_m int,
  kcal       int,
  floors     int,
  source     text not null,
  tz         text not null,
  updated_at timestamptz not null default now(),
  primary key (profile_id, local_date)
);

-- ---------- one device credits one profile per local day ----------
-- Casual anti-cheat for "one phone, several household profiles". A
-- determined user can fake a device id; this is not a security boundary.
create table if not exists public.step_device_days (
  device_id  text not null,
  local_date date not null,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  primary key (device_id, local_date)
);

-- ---------- incremental totals used by leaderboards ----------
create table if not exists public.period_totals (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  period     text not null check (period in ('day', 'week')),
  period_key text not null,            -- day: 'YYYY-MM-DD'; week: Monday 'YYYY-MM-DD'
  steps      int  not null default 0,
  updated_at timestamptz not null default now(),
  primary key (profile_id, period, period_key)
);
create index if not exists period_totals_board_idx
  on public.period_totals (period, period_key, steps desc, profile_id);

-- ---------- RLS: read own profiles' data only; no client writes ----------
alter table public.step_day_sources enable row level security;
alter table public.step_days        enable row level security;
alter table public.step_device_days enable row level security;
alter table public.period_totals    enable row level security;

revoke all on public.step_day_sources, public.step_days,
              public.step_device_days, public.period_totals
  from anon, authenticated;
grant select on public.step_days, public.period_totals to authenticated;

drop policy if exists "own steps: read" on public.step_days;
create policy "own steps: read" on public.step_days
  for select to authenticated
  using (exists (select 1 from public.profiles p
                 where p.id = step_days.profile_id and p.account_id = auth.uid()));

drop policy if exists "own totals: read" on public.period_totals;
create policy "own totals: read" on public.period_totals
  for select to authenticated
  using (exists (select 1 from public.profiles p
                 where p.id = period_totals.profile_id and p.account_id = auth.uid()));
-- step_day_sources and step_device_days: RLS on, no policies, no grants = no client access.

-- ---------- resolve the day from its sources ----------
create or replace function public.recompute_step_day(p_profile_id uuid, p_date date)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.step_day_sources%rowtype;
begin
  -- The health store wins whenever it has data for the day; otherwise the
  -- phone sensor. Never the sum of both.
  select * into r
    from public.step_day_sources
   where profile_id = p_profile_id and local_date = p_date
   order by (source = 'health_store') desc, steps desc
   limit 1;

  if not found then
    delete from public.step_days where profile_id = p_profile_id and local_date = p_date;
    return;
  end if;

  insert into public.step_days (profile_id, local_date, steps, distance_m, kcal, floors, source, tz, updated_at)
  values (p_profile_id, p_date, r.steps, r.distance_m, r.kcal, r.floors, r.source, r.tz, now())
  on conflict (profile_id, local_date) do update
    set steps = excluded.steps, distance_m = excluded.distance_m, kcal = excluded.kcal,
        floors = excluded.floors, source = excluded.source, tz = excluded.tz,
        updated_at = excluded.updated_at;
end;
$$;
revoke all on function public.recompute_step_day(uuid, date) from public, anon, authenticated;

-- ---------- keep period_totals in step with step_days ----------
create or replace function public.maintain_period_totals()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_profile uuid;
  v_date    date;
  v_delta   int;
  v_new_day int;
begin
  if tg_op = 'DELETE' then
    v_profile := old.profile_id; v_date := old.local_date;
    v_delta := -old.steps;       v_new_day := 0;
  elsif tg_op = 'UPDATE' then
    v_profile := new.profile_id; v_date := new.local_date;
    v_delta := new.steps - old.steps; v_new_day := new.steps;
  else
    v_profile := new.profile_id; v_date := new.local_date;
    v_delta := new.steps;        v_new_day := new.steps;
  end if;

  if tg_op = 'DELETE' then
    -- Profile deletion cascades here too; the totals rows may already be gone.
    update public.period_totals set steps = greatest(steps + v_delta, 0), updated_at = now()
     where profile_id = v_profile and period = 'week'
       and period_key = date_trunc('week', v_date)::date::text;
    delete from public.period_totals
     where profile_id = v_profile and period = 'day' and period_key = v_date::text;
    return old;
  end if;

  insert into public.period_totals (profile_id, period, period_key, steps)
  values (v_profile, 'day', v_date::text, v_new_day)
  on conflict (profile_id, period, period_key)
    do update set steps = excluded.steps, updated_at = now();

  insert into public.period_totals (profile_id, period, period_key, steps)
  values (v_profile, 'week', date_trunc('week', v_date)::date::text, v_delta)
  on conflict (profile_id, period, period_key)
    do update set steps = public.period_totals.steps + v_delta, updated_at = now();

  return new;
end;
$$;
drop trigger if exists step_days_totals on public.step_days;
create trigger step_days_totals
  after insert or update or delete on public.step_days
  for each row execute function public.maintain_period_totals();

-- ---------- THE write path ----------
-- p_days: [{local_date, tz_offset_min, source, steps, observed_at?, distance_m?, kcal?, floors?}, ...]
-- Returns one result object per input item: {local_date, status, reason?}.
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

    if v_reason is null then
      insert into public.step_device_days (device_id, local_date, profile_id)
      values (p_device_id, v_date, p_profile_id)
      on conflict (device_id, local_date) do nothing;

      select profile_id into v_device_profile from public.step_device_days
       where device_id = p_device_id and local_date = v_date;
      if v_device_profile <> p_profile_id then
        v_reason := 'device_in_use';
      end if;
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
