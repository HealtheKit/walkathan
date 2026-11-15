-- =====================================================================
-- 0018_fresh_start: after "set to zero" the walker starts from ZERO too.
--
-- Before: a reset only changed event scoring on the server. The phone still
-- held the whole day's steps, so as soon as it synced (for example right
-- after step access was switched on) the Walk screen showed the old number.
--
-- Now a reset stamps profiles.count_from. The app reads it and counts that
-- day's steps only FROM that moment (the health store can be asked for an
-- exact interval), then uploads the fresh total marked with counted_from.
--   * The Walk screen, the Activity history for that day, and the boards
--     all restart from zero and agree with each other.
--   * A total marked counted_from >= the reset is taken as it is; an
--     unmarked total (older app version, or a phone that has not heard of
--     the reset yet) still goes through the time rule of 0017.
--   * Undo clears count_from; the phone then uploads the full day again.
-- Earlier days are not changed.
-- =====================================================================

alter table public.profiles         add column if not exists count_from timestamptz;
alter table public.step_day_sources add column if not exists counted_from timestamptz;
alter table public.step_days        add column if not exists counted_from timestamptz;

create or replace function public.recompute_step_day(p_profile_id uuid, p_date date)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r public.step_day_sources%rowtype;
begin
  select * into r from public.step_day_sources
   where profile_id = p_profile_id and local_date = p_date
   order by (source = 'health_store') desc, steps desc limit 1;
  if not found then
    delete from public.step_days where profile_id = p_profile_id and local_date = p_date;
    return;
  end if;
  insert into public.step_days (profile_id, local_date, steps, distance_m, kcal, floors, source, tz, updated_at, hours, counted_from)
  values (p_profile_id, p_date, r.steps, r.distance_m, r.kcal, r.floors, r.source, r.tz, now(), r.hours, r.counted_from)
  on conflict (profile_id, local_date) do update
    set steps = excluded.steps, distance_m = excluded.distance_m, kcal = excluded.kcal,
        floors = excluded.floors, source = excluded.source, tz = excluded.tz,
        updated_at = excluded.updated_at, hours = excluded.hours,
        counted_from = excluded.counted_from;
end;
$$;

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
  v_hours     int[];
  v_from      timestamptz;
  v_count_from timestamptz;
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

  -- A phone this login has not been approved on cannot upload (see 0013).
  if public.ensure_login_device(p_device_id, null) <> 'approved' then
    return (select coalesce(jsonb_agg(jsonb_build_object(
              'local_date', x ->> 'local_date', 'status', 'rejected', 'reason', 'device_not_approved')), '[]'::jsonb)
            from jsonb_array_elements(p_days) as x);
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

  select count_from into v_count_from from public.profiles where id = p_profile_id;

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
      v_hours  := case when jsonb_typeof(v_item -> 'hours') = 'array'
                       then array(select (h #>> '{}')::int from jsonb_array_elements(v_item -> 'hours') h)
                  end;
      -- When the client read the value; never trusted into the future.
      v_obs    := least(coalesce(nullif(v_item ->> 'observed_at', '')::timestamptz, now()),
                        now() + interval '5 minutes');
      v_local_now := (now() at time zone 'UTC') + make_interval(mins => v_off);
      -- "This total only contains steps since <time>": the phone applied a
      -- count reset itself. Trusted only when it matches the profile's reset.
      v_from := nullif(v_item ->> 'counted_from', '')::timestamptz;
      if v_from is not null and (v_count_from is null
           or v_from < v_count_from - interval '1 minute'
           or v_from > now() + interval '5 minutes') then
        v_from := null;
      end if;
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
      elsif v_hours is not null and (array_length(v_hours, 1) <> 24
            or exists (select 1 from unnest(v_hours) h where h is null or h < 0 or h > 14400)
            or (select sum(h) from unnest(v_hours) h) > v_steps + 50) then
        v_reason := 'bad_hours';
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
        (profile_id, local_date, source, steps, distance_m, kcal, floors, tz, observed_at, updated_at, hours, counted_from)
      values (p_profile_id, v_date, v_src, v_steps, v_dist, v_kcal, v_floors, v_tz, v_obs, now(), v_hours, v_from)
      on conflict (profile_id, local_date, source) do update
        set -- health_store: newest reading wins (may CORRECT downward).
            -- phone_sensor: never goes down.
            distance_m = case when ((s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                                or (excluded.counted_from is not null and (s.counted_from is null or excluded.counted_from > s.counted_from)))
                              then excluded.distance_m else s.distance_m end,
            kcal       = case when ((s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                                or (excluded.counted_from is not null and (s.counted_from is null or excluded.counted_from > s.counted_from)))
                              then excluded.kcal else s.kcal end,
            floors     = case when ((s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                                or (excluded.counted_from is not null and (s.counted_from is null or excluded.counted_from > s.counted_from)))
                              then excluded.floors else s.floors end,
            hours      = case when ((s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                                or (excluded.counted_from is not null and (s.counted_from is null or excluded.counted_from > s.counted_from)))
                              then coalesce(excluded.hours, s.hours) else s.hours end,
            tz         = case when ((s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                                or (excluded.counted_from is not null and (s.counted_from is null or excluded.counted_from > s.counted_from)))
                              then excluded.tz else s.tz end,
            -- a total freshly cut at a count reset replaces the old one,
            -- even for the sensor (which otherwise never goes down)
            counted_from = case when ((s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                                or (excluded.counted_from is not null and (s.counted_from is null or excluded.counted_from > s.counted_from)))
                              then excluded.counted_from else s.counted_from end,
            steps      = case when (excluded.counted_from is not null and (s.counted_from is null or excluded.counted_from > s.counted_from))
                              then excluded.steps
                              when s.source = 'health_store'
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

create or replace function public.event_days(p_event uuid, p_to date)
returns table (profile_id uuid, local_date date, steps int, distance_m int, kcal int,
               hours int[], raw_steps int, corrected text)
language sql stable security definer set search_path = ''
as $$
  with src as (
    select sd.profile_id, sd.local_date, sd.distance_m, sd.kcal, sd.hours, sd.steps as day_steps,
           b.reset_date, b.baseline_steps, b.hour_baseline,
           -- the reset moment on this row's own clock
           (b.reset_at at time zone 'UTC') + public.tz_interval(sd.tz) as rl,
           b.reset_at is not null as has_reset,
           (sd.counted_from is not null and sd.counted_from >= b.reset_at - interval '1 minute') as clean,
           c.action, c.cap_steps, e.daily_cap
      from public.events e
      join public.event_accounts ea on ea.event_id = e.id and ea.status = 'active'
      join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
      join public.step_days sd on sd.profile_id = p.id
           and sd.local_date between e.starts_on and least(e.ends_on, p_to)
      left join public.step_corrections c on c.profile_id = sd.profile_id and c.local_date = sd.local_date
      left join public.event_resets b on b.event_id = e.id and b.profile_id = sd.profile_id
     where e.id = p_event
  ),
  base as (
    select s.*,
           case
             when not has_reset then day_steps
             -- the phone already cut this total at the reset: all of it is new
             when clean then day_steps
             -- by time, when this row has a clock and an hourly breakdown
             when rl is not null and local_date < rl::date then 0
             when rl is not null and local_date > rl::date then day_steps
             when rl is not null and hours is not null then
               least(day_steps,
                     coalesce((select sum(h.v) from unnest(hours) with ordinality h(v, i)
                                where h.i - 1 > extract(hour from rl)::int), 0)::int
                     + greatest(coalesce(hours[extract(hour from rl)::int + 1], 0) - hour_baseline, 0))
             -- fallback: the baseline taken at the reset
             when local_date < reset_date then 0
             when local_date = reset_date then greatest(day_steps - baseline_steps, 0)
             else day_steps
           end as adj
      from src s
  )
  select profile_id, local_date,
         least(case action when 'exclude' then 0
                           when 'cap' then least(adj, cap_steps)
                           else adj end,
               coalesce(daily_cap, 100000)),
         -- distance and energy follow the steps that count
         case when adj = day_steps then distance_m
              when adj = 0 or day_steps = 0 then 0
              else (distance_m::numeric * adj / day_steps)::int end,
         case when adj = day_steps then kcal
              when adj = 0 or day_steps = 0 then 0
              else (kcal::numeric * adj / day_steps)::int end,
         case when adj = day_steps then hours else null end,
         adj, action
    from base;
$$;

create or replace function public.admin_reset_counts(
  p_event uuid, p_profile uuid default null, p_local_date date default null, p_note text default null
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := public.clamp_local_date(p_local_date);
  v_now timestamp := now() at time zone 'UTC';
  v_n int;
begin
  perform public.require_event_manage(p_event);
  if char_length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'a reason is required' using errcode = 'invalid_parameter_value';
  end if;
  if p_profile is not null and not exists (
       select 1 from public.event_accounts ea join public.profiles p on p.account_id = ea.account_id
        where ea.event_id = p_event and p.id = p_profile) then
    raise exception 'profile is not on this event' using errcode = 'no_data_found';
  end if;

  -- Each profile is reset at ITS OWN latest recorded day (never before the
  -- caller's today). Participants live in other time zones, so their "today"
  -- can already be tomorrow here; resetting only at the caller's date would
  -- leave that day counting.
  insert into public.event_resets as r
    (event_id, profile_id, reset_date, baseline_steps, hour_baseline, reset_at, reset_by, note)
  select p_event, p.id, d.reset_date,
         coalesce((select sd.steps from public.step_days sd
                    where sd.profile_id = p.id and sd.local_date = d.reset_date), 0),
         -- steps the server already has for the hour the reset happens in,
         -- on that profile's own clock
         coalesce((select sd.hours[extract(hour from v_now + public.tz_interval(sd.tz))::int + 1]
                     from public.step_days sd
                    where sd.profile_id = p.id
                      and public.tz_interval(sd.tz) is not null
                      and sd.local_date = (v_now + public.tz_interval(sd.tz))::date
                    limit 1), 0),
         now(), auth.uid(), btrim(p_note)
    from public.event_accounts ea
    join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
    cross join lateral (
      select greatest(v_today, coalesce((select max(sd2.local_date) from public.step_days sd2
                                          where sd2.profile_id = p.id
                                            and sd2.local_date <= v_today + 2), v_today)) as reset_date) d
   where ea.event_id = p_event and (p_profile is null or p.id = p_profile)
  on conflict (event_id, profile_id) do update
    set reset_date = excluded.reset_date, baseline_steps = excluded.baseline_steps,
        hour_baseline = excluded.hour_baseline,
        reset_at = now(), reset_by = excluded.reset_by, note = excluded.note;
  get diagnostics v_n = row_count;

  -- The walker's own phone starts again from zero too (Walk screen).
  update public.profiles p set count_from = now()
   where p.id in (select r.profile_id from public.event_resets r
                   where r.event_id = p_event and (p_profile is null or r.profile_id = p_profile));

  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), case when p_profile is null then 'counts.reset_all' else 'counts.reset_profile' end,
          p_profile, jsonb_build_object('event_id', p_event, 'profiles', v_n, 'date', v_today, 'note', btrim(p_note)));
  return v_n;
end;
$$;

create or replace function public.admin_undo_reset(p_event uuid, p_profile uuid default null)
returns int
language plpgsql security definer set search_path = ''
as $$
declare v_n int;
begin
  perform public.require_event_manage(p_event);
  with gone as (
    delete from public.event_resets
     where event_id = p_event and (p_profile is null or profile_id = p_profile)
    returning profile_id
  ),
  upd as (
    -- back to whatever other reset still applies to the profile (or none)
    update public.profiles p
       set count_from = (select max(r.reset_at) from public.event_resets r
                          where r.profile_id = p.id and r.event_id <> p_event)
     where p.id in (select profile_id from gone)
    returning 1
  )
  select (select count(*) from gone) + 0 * (select count(*) from upd) into v_n;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'counts.reset_undo', p_profile, jsonb_build_object('event_id', p_event, 'profiles', v_n));
  return v_n;
end;
$$;

revoke all on function public.recompute_step_day(uuid, date) from public, anon, authenticated;
revoke all on function public.event_days(uuid, date) from public, anon, authenticated;
revoke all on function public.ingest_steps(uuid, text, jsonb) from public, anon;
grant execute on function public.ingest_steps(uuid, text, jsonb) to authenticated;
