-- =====================================================================
-- 0017_reset_by_time: a reset is decided by TIME, not by what had synced.
--
-- Before: a reset stored the steps the SERVER knew at that moment. Steps a
-- phone had taken earlier but not uploaded yet arrived afterwards and were
-- counted as new (a phone that last synced hours ago brought in hundreds).
--
-- Now: on the reset day only steps in hours AFTER the reset count, using
-- the hourly breakdown each phone uploads. Late uploads of earlier hours
-- are ignored however late they arrive.
--   * hours before the reset hour: 0
--   * the reset hour itself: only what is above what the server had then
--     (so walking right after a reset counts at once; at most the unsynced
--     part of that single hour can slip in)
--   * hours after: counted
--   * days before / after the reset day: 0 / counted in full
-- A day with no hourly breakdown falls back to the baseline rule.
-- =====================================================================

alter table public.event_resets
  add column if not exists hour_baseline int not null default 0 check (hour_baseline >= 0);

-- '+05:30' / '-08:00' -> interval; null when the text is not an offset.
create or replace function public.tz_interval(p_tz text)
returns interval
language sql immutable set search_path = ''
as $$
  select case when p_tz ~ '^[+-][0-9]{2}:[0-9]{2}$'
              then (case when left(p_tz, 1) = '-' then -1 else 1 end)
                   * make_interval(hours => substr(p_tz, 2, 2)::int, mins => substr(p_tz, 5, 2)::int)
         end;
$$;
revoke all on function public.tz_interval(text) from public, anon, authenticated;

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
revoke all on function public.event_days(uuid, date) from public, anon, authenticated;

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

  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), case when p_profile is null then 'counts.reset_all' else 'counts.reset_profile' end,
          p_profile, jsonb_build_object('event_id', p_event, 'profiles', v_n, 'date', v_today, 'note', btrim(p_note)));
  return v_n;
end;
$$;
