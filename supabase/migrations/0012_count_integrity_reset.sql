-- =====================================================================
-- 0012_count_integrity_reset: trustworthy event counts and count resets.
--
--  * event_resets: a Super Admin / organizer can set event counts back to
--    ZERO for everyone or for one profile. Nothing is deleted: a reset
--    stores a baseline (the profile's steps for today at that moment) and
--    event scoring ignores everything before it. A reset can be undone.
--    Personal step history (Walk / Activity tabs) is not touched.
--  * Organizers of an event (event_organizers, 0011) may view and reset
--    THAT event; they cannot touch other events.
--  * admin_validate_counts: independent recount of the whole pipeline
--    (sources -> daily totals -> weekly totals -> event totals -> boards),
--    reporting any mismatch, with an optional repair.
--  * admin_participant_days now shows the raw sources and what counts.
-- =====================================================================

create table if not exists public.event_resets (
  event_id       uuid not null references public.events (id) on delete cascade,
  profile_id     uuid not null references public.profiles (id) on delete cascade,
  reset_date     date not null,          -- days BEFORE this date count as 0
  baseline_steps int  not null default 0 check (baseline_steps >= 0),
                                          -- steps already on reset_date at reset time
  reset_at       timestamptz not null default now(),
  reset_by       uuid references auth.users (id) on delete set null,
  note           text,
  primary key (event_id, profile_id)
);
alter table public.event_resets enable row level security;
revoke all on public.event_resets from anon, authenticated;

-- ---------- who may act on an event ----------
create or replace function public.can_manage_event(p_event uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select public.staff_can('manage') or public.is_event_organizer(p_event); $$;

create or replace function public.can_access_event(p_event uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$ select public.staff_can('view') or public.is_event_organizer(p_event); $$;

create or replace function public.require_event_access(p_event uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not coalesce(public.can_access_event(p_event), false) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

create or replace function public.require_event_manage(p_event uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not coalesce(public.can_manage_event(p_event), false) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- ---------- effective steps for an event (now honours resets) ----------
-- steps  = day total, minus the reset baseline, then correction, then cap
-- A day before the profile's reset date counts as 0 (distance too).
create or replace function public.event_days(p_event uuid, p_to date)
returns table (profile_id uuid, local_date date, steps int, distance_m int, kcal int,
               hours int[], raw_steps int, corrected text)
language sql stable security definer set search_path = ''
as $$
  with base as (
    select sd.profile_id, sd.local_date, sd.distance_m, sd.kcal, sd.hours, sd.steps as day_steps,
           case when b.reset_date is null then sd.steps
                when sd.local_date < b.reset_date then 0
                when sd.local_date = b.reset_date then greatest(sd.steps - b.baseline_steps, 0)
                else sd.steps end as adj,
           (b.reset_date is not null and sd.local_date <= b.reset_date) as touched,
           c.action, c.cap_steps, e.daily_cap
      from public.events e
      join public.event_accounts ea on ea.event_id = e.id and ea.status = 'active'
      join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
      join public.step_days sd on sd.profile_id = p.id
           and sd.local_date between e.starts_on and least(e.ends_on, p_to)
      left join public.step_corrections c on c.profile_id = sd.profile_id and c.local_date = sd.local_date
      left join public.event_resets b on b.event_id = e.id and b.profile_id = sd.profile_id
     where e.id = p_event
  )
  select profile_id, local_date,
         least(case action when 'exclude' then 0
                           when 'cap' then least(adj, cap_steps)
                           else adj end,
               coalesce(daily_cap, 100000)),
         -- distance and energy follow the steps that count
         case when not touched then distance_m
              when adj = 0 or day_steps = 0 then 0
              else (distance_m::numeric * adj / day_steps)::int end,
         case when not touched then kcal
              when adj = 0 or day_steps = 0 then 0
              else (kcal::numeric * adj / day_steps)::int end,
         case when touched then null else hours end,
         adj, action
    from base;
$$;
revoke all on function public.event_days(uuid, date) from public, anon, authenticated;

-- ---------- event views for staff AND the event's organizers ----------
drop function if exists public.admin_event_roster(uuid);
create or replace function public.admin_event_roster(p_event_id uuid)
returns table (account_id uuid, email text, added_at timestamptz, profile_count bigint,
               has_signed_in boolean, status text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.require_event_access(p_event_id);
  return query
    select u.id, u.email::text, ea.added_at,
           (select count(*) from public.profiles p where p.account_id = u.id),
           u.last_sign_in_at is not null, ea.status
      from public.event_accounts ea join auth.users u on u.id = ea.account_id
     where ea.event_id = p_event_id order by u.email;
end;
$$;

create or replace function public.admin_participants(p_event uuid, p_local_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  e public.events%rowtype;
  v_today date := public.clamp_local_date(p_local_date);
  v_to date; v_days int;
begin
  perform public.require_event_access(p_event);
  select * into e from public.events where id = p_event;
  if not found then raise exception 'event not found' using errcode = 'no_data_found'; end if;
  v_to := least(e.ends_on, v_today);
  v_days := greatest(v_to - e.starts_on + 1, 0);

  return coalesce((
    with people as (
      select p.id, public.profile_label(p.display_name) as name, p.sex, u.email::text as email,
             ea.status, ea.account_id,
             (select max(pd.last_used_at) from public.profile_devices pd where pd.profile_id = p.id) as last_sync
        from public.event_accounts ea
        join auth.users u on u.id = ea.account_id
        join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
       where ea.event_id = p_event
    ),
    days as (select * from public.event_days(p_event, v_to)),
    series as (
      -- every event day for every person, zero-filled, for consistency
      select pe.id, g.d::date as d, coalesce(dd.steps, 0) as steps
        from people pe
        cross join generate_series(e.starts_on, v_to, interval '1 day') g(d)
        left join days dd on dd.profile_id = pe.id and dd.local_date = g.d::date
    ),
    m as (
      select pe.*,
             coalesce((select sum(steps) from days where profile_id = pe.id), 0)::bigint as total,
             coalesce((select sum(distance_m) from days where profile_id = pe.id), 0)::bigint as distance_m,
             (select count(*) from days where profile_id = pe.id and steps > 0) as active_days,
             (select max(local_date) from days where profile_id = pe.id and steps > 0) as last_active,
             (select coalesce(stddev_pop(steps), 0) / nullif(avg(steps), 0) from series where id = pe.id) as cv,
             (select coalesce(sum(steps), 0) from series where id = pe.id and d > v_to - 7) as last7,
             (select coalesce(sum(steps), 0) from series where id = pe.id and d between v_to - 13 and v_to - 7) as prev7,
             (select count(*) from days where profile_id = pe.id
                and (raw_steps > greatest(coalesce(e.daily_cap, 40000), 40000))
                and corrected is null) as high_days,
             (select count(*) from days where profile_id = pe.id and corrected is not null) as corrected_days,
             (select r.award || ' (' || r.status || ')' from public.event_rewards r
               where r.event_id = p_event and r.profile_id = pe.id) as reward,
             (select b.reset_date from public.event_resets b
               where b.event_id = p_event and b.profile_id = pe.id) as reset_on
        from people pe
    )
    select jsonb_agg(jsonb_build_object(
             'profile_id', id, 'account_id', account_id, 'name', name, 'email', email,
             'sex', sex, 'status', status, 'total_steps', total, 'distance_m', distance_m,
             'active_days', active_days, 'event_days', v_days,
             'active_pct', case when v_days > 0 then round(100.0 * active_days / v_days) else 0 end,
             'avg_daily', case when v_days > 0 then total / v_days else 0 end,
             -- 100 = the same every day, 0 = very uneven (zeros included)
             'consistency', case when cv is null then 0 else greatest(0, round(100 * (1 - least(cv, 1)))) end,
             'last_active', last_active, 'last_sync', last_sync,
             'improvement', last7 - prev7,
             'high_days', high_days, 'corrected_days', corrected_days, 'reward', reward,
             'reset_on', reset_on,
             'reward_eligible',
               coalesce(total >= e.reward_min_steps, true)
               and coalesce(case when v_days > 0 then 100.0 * active_days / v_days else 0 end
                            >= e.reward_min_active_pct, true)
               and (e.reward_min_steps is not null or e.reward_min_active_pct is not null),
             'flags', to_jsonb(array_remove(array[
                 case when total = 0 and v_days >= 2 then 'no_data' end,
                 case when last_active is not null and last_active < v_to - 2 then 'dropout_risk' end,
                 case when last_sync is null or last_sync < now() - interval '48 hours' then 'sync_stale' end,
                 case when high_days > 0 then 'high_values' end,
                 case when v_days >= 5 and cv is not null and cv > 0.8 then 'low_consistency' end
               ], null)))
           order by total desc, name)
      from m), '[]'::jsonb);
end;
$$;

create or replace function public.admin_event_overview(p_event uuid, p_local_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  e public.events%rowtype;
  v_today date := public.clamp_local_date(p_local_date);
  v_to date;
  v_people jsonb;
begin
  perform public.require_event_access(p_event);
  select * into e from public.events where id = p_event;
  if not found then raise exception 'event not found' using errcode = 'no_data_found'; end if;
  v_to := least(e.ends_on, v_today);
  v_people := public.admin_participants(p_event, p_local_date);

  return jsonb_build_object(
    'event', to_jsonb(e),
    'today', v_today,
    'participants', (select count(*) from jsonb_array_elements(v_people) x where x ->> 'status' = 'active'),
    'active_participants', (select count(*) from jsonb_array_elements(v_people) x
                             where x ->> 'status' = 'active' and (x ->> 'active_days')::int > 0),
    'active_today', (select count(distinct profile_id) from public.event_days(p_event, v_to)
                      where local_date = v_to and steps > 0),
    'total_steps', (select coalesce(sum((x ->> 'total_steps')::bigint), 0) from jsonb_array_elements(v_people) x),
    'total_distance_m', (select coalesce(sum((x ->> 'distance_m')::bigint), 0) from jsonb_array_elements(v_people) x),
    'synced_48h_pct', (select case when count(*) = 0 then 0 else round(100.0 * count(*) filter (where not (x -> 'flags') ? 'sync_stale') / count(*)) end
                         from jsonb_array_elements(v_people) x where x ->> 'status' = 'active'),
    'last_board_update', (select max(sd.updated_at) from public.event_accounts ea
                            join public.profiles p on p.account_id = ea.account_id
                            join public.step_days sd on sd.profile_id = p.id
                           where ea.event_id = p_event),
    'reward_eligible', (select count(*) from jsonb_array_elements(v_people) x where (x ->> 'reward_eligible')::boolean),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('date', g.d::date,
                 'active', (select count(distinct profile_id) from public.event_days(p_event, v_to) d
                             where d.local_date = g.d::date and d.steps > 0),
                 'steps', (select coalesce(sum(steps), 0) from public.event_days(p_event, v_to) d
                             where d.local_date = g.d::date)) order by g.d)
               from generate_series(e.starts_on, v_to, interval '1 day') g(d)), '[]'::jsonb),
    'participants_detail', v_people);
end;
$$;

create or replace function public.admin_participant_days(p_event uuid, p_profile uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare e public.events%rowtype;
begin
  perform public.require_event_access(p_event);
  select * into e from public.events where id = p_event;
  -- every day with data, the raw sources behind it, and what actually counts
  return coalesce((select jsonb_agg(jsonb_build_object(
             'date', sd.local_date, 'raw_steps', sd.steps, 'source', sd.source,
             'sources', (select jsonb_agg(jsonb_build_object('source', s.source, 'steps', s.steps)
                                          order by s.source)
                           from public.step_day_sources s
                          where s.profile_id = sd.profile_id and s.local_date = sd.local_date),
             'counted', coalesce(ed.steps, 0),
             'hours', to_jsonb(sd.hours), 'updated_at', sd.updated_at,
             'correction', c.action, 'cap_steps', c.cap_steps, 'reason', c.reason,
             'before_reset', b.reset_date is not null and sd.local_date < b.reset_date)
           order by sd.local_date desc)
      from public.step_days sd
      left join public.step_corrections c on c.profile_id = sd.profile_id and c.local_date = sd.local_date
      left join public.event_resets b on b.event_id = p_event and b.profile_id = sd.profile_id
      left join public.event_days(p_event, e.ends_on) ed
             on ed.profile_id = sd.profile_id and ed.local_date = sd.local_date
     where sd.profile_id = p_profile and sd.local_date between e.starts_on and e.ends_on), '[]'::jsonb);
end;
$$;


create or replace function public.admin_list_events()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if auth.uid() is null or not (public.staff_can('view')
       or exists (select 1 from public.event_organizers where user_id = auth.uid())) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((select jsonb_agg(to_jsonb(e) || jsonb_build_object(
             'member_count', (select count(*) from public.event_accounts ea
                               where ea.event_id = e.id and ea.status = 'active'))
           order by e.starts_on desc, e.created_at desc)
      from public.events e
     where public.can_access_event(e.id)), '[]'::jsonb);
end;
$$;

-- ---------- count resets ----------
-- p_profile null = everyone on the event's roster. p_local_date is the
-- caller's local "today" (clamped to UTC +-1 day).
create or replace function public.admin_reset_counts(
  p_event uuid, p_profile uuid default null, p_local_date date default null, p_note text default null
) returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := public.clamp_local_date(p_local_date);
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

  insert into public.event_resets as r (event_id, profile_id, reset_date, baseline_steps, reset_by, note)
  select p_event, p.id, v_today,
         coalesce((select sd.steps from public.step_days sd
                    where sd.profile_id = p.id and sd.local_date = v_today), 0),
         auth.uid(), btrim(p_note)
    from public.event_accounts ea
    join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
   where ea.event_id = p_event and (p_profile is null or p.id = p_profile)
  on conflict (event_id, profile_id) do update
    set reset_date = excluded.reset_date, baseline_steps = excluded.baseline_steps,
        reset_at = now(), reset_by = excluded.reset_by, note = excluded.note;
  get diagnostics v_n = row_count;

  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), case when p_profile is null then 'counts.reset_all' else 'counts.reset_profile' end,
          p_profile, jsonb_build_object('event_id', p_event, 'profiles', v_n, 'date', v_today, 'note', btrim(p_note)));
  return v_n;
end;
$$;

-- Undo: counts come back (nothing was deleted). p_profile null = undo all.
create or replace function public.admin_undo_reset(p_event uuid, p_profile uuid default null)
returns int
language plpgsql security definer set search_path = ''
as $$
declare v_n int;
begin
  perform public.require_event_manage(p_event);
  delete from public.event_resets
   where event_id = p_event and (p_profile is null or profile_id = p_profile);
  get diagnostics v_n = row_count;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'counts.reset_undo', p_profile, jsonb_build_object('event_id', p_event, 'profiles', v_n));
  return v_n;
end;
$$;

-- ---------- independent recount ----------
-- Recomputes everything from the raw per-source rows and compares with what
-- is stored and what the boards report. p_repair fixes day and period totals.
create or replace function public.admin_validate_counts(p_event uuid default null, p_repair boolean default false)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_checks jsonb := '[]'::jsonb;
  v_bad    jsonb;
  v_n      int;
  e        public.events%rowtype;
  v_to     date;
  v_a bigint; v_b bigint; v_c bigint;
  v_scope  uuid[];
begin
  if p_event is null then
    perform public.require_staff('verify');
  else
    perform public.require_event_access(p_event);
  end if;
  if p_repair then
    if p_event is null then perform public.require_staff('manage');
    else perform public.require_event_manage(p_event); end if;
  end if;

  if p_event is not null then
    select * into e from public.events where id = p_event;
    if not found then raise exception 'event not found' using errcode = 'no_data_found'; end if;
    select array_agg(p.id) into v_scope
      from public.event_accounts ea join public.profiles p on p.account_id = ea.account_id
     where ea.event_id = p_event;
    -- the same cut-off the dashboards use: the event's end, or today
    v_to := least(e.ends_on, public.clamp_local_date(null));
  end if;
  v_scope := coalesce(v_scope, (select array_agg(id) from public.profiles));

  -- 1. daily totals vs the raw sources (health store wins, else the larger)
  drop table if exists _best;
  create temp table _best on commit drop as
    select distinct on (s.profile_id, s.local_date)
           s.profile_id, s.local_date, s.steps, s.source
      from public.step_day_sources s
     where s.profile_id = any (v_scope)
     order by s.profile_id, s.local_date, (s.source = 'health_store') desc, s.steps desc;

  select count(*), coalesce(jsonb_agg(x) filter (where rn <= 10), '[]'::jsonb) into v_n, v_bad
    from (select jsonb_build_object('profile_id', coalesce(b.profile_id, d.profile_id),
                   'date', coalesce(b.local_date, d.local_date),
                   'sources_say', b.steps, 'stored', d.steps) as x,
                 row_number() over () as rn
            from _best b
            full join (select * from public.step_days where profile_id = any (v_scope)) d
              on d.profile_id = b.profile_id and d.local_date = b.local_date
           where b.steps is distinct from d.steps) q;
  v_checks := v_checks || jsonb_build_object('check', 'daily_totals_match_sources',
      'ok', v_n = 0, 'mismatches', v_n, 'sample', v_bad);
  if p_repair and v_n > 0 then
    delete from public.step_days d where d.profile_id = any (v_scope)
      and not exists (select 1 from _best b where b.profile_id = d.profile_id and b.local_date = d.local_date);
    perform public.recompute_step_day(b.profile_id, b.local_date)
       from _best b
       left join public.step_days d on d.profile_id = b.profile_id and d.local_date = b.local_date
      where d.steps is distinct from b.steps;
  end if;

  -- 2. daily / weekly leaderboard totals vs daily totals
  select count(*), coalesce(jsonb_agg(x) filter (where rn <= 10), '[]'::jsonb) into v_n, v_bad
    from (select jsonb_build_object('profile_id', coalesce(t.profile_id, w.profile_id),
                   'week', coalesce(t.period_key, w.period_key), 'stored', t.steps, 'recount', w.steps) as x,
                 row_number() over () as rn
            from (select profile_id, period_key, steps from public.period_totals
                   where period = 'week' and profile_id = any (v_scope)) t
            full join (select profile_id, date_trunc('week', local_date)::date::text as period_key,
                              sum(steps)::int as steps
                         from public.step_days where profile_id = any (v_scope) group by 1, 2) w
              on w.profile_id = t.profile_id and w.period_key = t.period_key
           where t.steps is distinct from w.steps) q;
  v_checks := v_checks || jsonb_build_object('check', 'weekly_totals_match_days',
      'ok', v_n = 0, 'mismatches', v_n, 'sample', v_bad);

  select count(*) into v_n
    from (select 1 from public.period_totals t
           where t.period = 'day' and t.profile_id = any (v_scope)
             and t.steps is distinct from (select sd.steps from public.step_days sd
                      where sd.profile_id = t.profile_id and sd.local_date = t.period_key::date)
          union all
          select 1 from public.step_days sd
           where sd.profile_id = any (v_scope)
             and not exists (select 1 from public.period_totals t where t.profile_id = sd.profile_id
                      and t.period = 'day' and t.period_key = sd.local_date::text)) q;
  v_checks := v_checks || jsonb_build_object('check', 'day_totals_match_days', 'ok', v_n = 0, 'mismatches', v_n);

  if p_repair then
    delete from public.period_totals where profile_id = any (v_scope);
    insert into public.period_totals (profile_id, period, period_key, steps)
      select profile_id, 'day', local_date::text, steps from public.step_days where profile_id = any (v_scope);
    insert into public.period_totals (profile_id, period, period_key, steps)
      select profile_id, 'week', date_trunc('week', local_date)::date::text, sum(steps)::int
        from public.step_days where profile_id = any (v_scope) group by 1, 3;
  end if;

  -- 3. implausible or duplicated data
  select count(*), coalesce(jsonb_agg(x) filter (where rn <= 10), '[]'::jsonb) into v_n, v_bad
    from (select jsonb_build_object('profile_id', sd.profile_id, 'date', sd.local_date, 'steps', sd.steps) as x,
                 row_number() over () as rn
            from public.step_days sd
           where sd.profile_id = any (v_scope) and sd.steps > 40000) q;
  v_checks := v_checks || jsonb_build_object('check', 'days_over_40000_steps',
      'ok', v_n = 0, 'mismatches', v_n, 'sample', v_bad, 'info', true);

  select count(*), coalesce(jsonb_agg(x) filter (where rn <= 10), '[]'::jsonb) into v_n, v_bad
    from (select jsonb_build_object('date', a.local_date, 'steps', a.steps,
                   'profile_a', a.profile_id, 'profile_b', b.profile_id) as x,
                 row_number() over () as rn
            from public.step_days a
            join public.profiles pa on pa.id = a.profile_id
            join public.profiles pb on pb.account_id = pa.account_id and pb.id > pa.id
            join public.step_days b on b.profile_id = pb.id and b.local_date = a.local_date and b.steps = a.steps
           where a.steps >= 500 and a.profile_id = any (v_scope)) q;
  v_checks := v_checks || jsonb_build_object('check', 'same_steps_on_two_profiles_of_one_login',
      'ok', v_n = 0, 'mismatches', v_n, 'sample', v_bad, 'info', true);

  -- 4. event totals: three independent routes must agree
  if p_event is not null then
    select coalesce(sum(steps), 0) into v_a from public.event_days(p_event, v_to);
    select coalesce(sum(steps), 0) into v_b
      from public.step_days sd
      join public.profiles p on p.id = sd.profile_id and p.deleted_at is null
      join public.event_accounts ea on ea.account_id = p.account_id and ea.event_id = p_event and ea.status = 'active'
      left join public.step_corrections c on c.profile_id = sd.profile_id and c.local_date = sd.local_date
     where sd.local_date between e.starts_on and v_to;
    -- b ignores corrections, caps and resets on purpose: it is the ceiling a is judged against
    select coalesce(sum((x ->> 'total_steps')::bigint), 0) into v_c
      from jsonb_array_elements(public.admin_participants(p_event, null)) x;
    v_checks := v_checks || jsonb_build_object('check', 'event_total_vs_participant_list',
        'ok', v_a = v_c, 'event_days_total', v_a, 'participant_list_total', v_c);
    v_checks := v_checks || jsonb_build_object('check', 'event_total_not_above_raw_days',
        'ok', v_a <= v_b, 'counted', v_a, 'raw_ceiling', v_b);
  end if;

  drop table if exists _best;
  insert into public.admin_audit_log (actor_id, action, details)
  values (auth.uid(), case when p_repair then 'counts.repair' else 'counts.validate' end,
          jsonb_build_object('event_id', p_event));
  return jsonb_build_object('event_id', p_event, 'repaired', p_repair,
    'ok', not exists (select 1 from jsonb_array_elements(v_checks) c
                       where (c ->> 'ok')::boolean is false and coalesce((c ->> 'info')::boolean, false) is false),
    'checks', v_checks);
end;
$$;

-- ---------- grants ----------
revoke all on function
  public.can_manage_event(uuid), public.can_access_event(uuid),
  public.require_event_access(uuid), public.require_event_manage(uuid),
  public.admin_event_roster(uuid), public.admin_participants(uuid, date),
  public.admin_event_overview(uuid, date), public.admin_participant_days(uuid, uuid),
  public.admin_list_events(), public.admin_reset_counts(uuid, uuid, date, text),
  public.admin_undo_reset(uuid, uuid), public.admin_validate_counts(uuid, boolean)
  from public, anon;
grant execute on function
  public.admin_event_roster(uuid), public.admin_participants(uuid, date),
  public.admin_event_overview(uuid, date), public.admin_participant_days(uuid, uuid),
  public.admin_list_events(), public.admin_reset_counts(uuid, uuid, date, text),
  public.admin_undo_reset(uuid, uuid), public.admin_validate_counts(uuid, boolean)
  to authenticated;

-- ---------- profile transfer keeps count resets (replaces the 0011 function) ----------

create or replace function public.decide_profile_transfer(
  p_id uuid, p_approve boolean, p_note text default null
) returns text
language plpgsql security definer set search_path = ''
as $$
declare
  r public.profile_transfer_requests%rowtype;
  s public.profiles%rowtype;
  t public.profiles%rowtype;
  v_date date;
  v_days int;
  v_steps bigint;
begin
  if not public.is_transfer_reviewer() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  select * into r from public.profile_transfer_requests where id = p_id for update;
  if not found then return 'not_found'; end if;
  if not public.can_review_transfer(r.account_id) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  if r.status <> 'pending' then return 'already_' || r.status; end if;
  -- only a Super Admin may approve their own request
  if r.account_id = auth.uid() and p_approve and not public.is_platform_admin() then
    raise exception 'you cannot approve your own request' using errcode = 'insufficient_privilege';
  end if;

  if not p_approve then
    update public.profile_transfer_requests
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(),
           decision_note = left(nullif(btrim(p_note), ''), 300)
     where id = p_id;
    insert into public.admin_audit_log (actor_id, action, target_id, details)
    values (auth.uid(), 'transfer.reject', r.source_profile_id, jsonb_build_object('request_id', p_id));
    return 'rejected';
  end if;

  select * into s from public.profiles where id = r.source_profile_id for update;
  select * into t from public.profiles where id = r.target_profile_id for update;
  if s.id is null or t.id is null or s.account_id <> t.account_id then
    -- a profile vanished since the request: close it, do nothing else
    update public.profile_transfer_requests
       set status = 'cancelled', decided_by = auth.uid(), decided_at = now(),
           decision_note = 'a profile no longer exists'
     where id = p_id;
    return 'profile_missing';
  end if;

  select count(*), coalesce(sum(steps), 0) into v_days, v_steps
    from public.step_days where profile_id = s.id;

  -- 1. step history: for the same (day, source) keep the larger reading
  insert into public.step_day_sources as x
    (profile_id, local_date, source, steps, distance_m, kcal, floors, tz, observed_at, updated_at)
  select t.id, o.local_date, o.source, o.steps, o.distance_m, o.kcal, o.floors, o.tz, o.observed_at, now()
    from public.step_day_sources o where o.profile_id = s.id
  on conflict (profile_id, local_date, source) do update
    set distance_m  = case when excluded.steps > x.steps then excluded.distance_m else x.distance_m end,
        kcal        = case when excluded.steps > x.steps then excluded.kcal else x.kcal end,
        floors      = case when excluded.steps > x.steps then excluded.floors else x.floors end,
        tz          = case when excluded.steps > x.steps then excluded.tz else x.tz end,
        steps       = greatest(x.steps, excluded.steps),
        observed_at = greatest(x.observed_at, excluded.observed_at),
        updated_at  = now();

  for v_date in select distinct local_date from public.step_day_sources where profile_id = s.id loop
    perform public.recompute_step_day(t.id, v_date);
  end loop;

  -- 2. rest days and audited corrections follow the data. UPDATE (re-point),
  --    not INSERT: rest_days has an insert trigger that only allows dates near
  --    today, which would reject genuine history. Rows that clash with an
  --    existing one on the new profile are dropped with the old profile.
  update public.rest_days rd set profile_id = t.id
   where rd.profile_id = s.id
     and not exists (select 1 from public.rest_days x
                      where x.profile_id = t.id and x.local_date = rd.local_date);
  update public.step_corrections sc set profile_id = t.id
   where sc.profile_id = s.id
     and not exists (select 1 from public.step_corrections x
                      where x.profile_id = t.id and x.local_date = sc.local_date);

  -- 2b. an event count reset on the old profile must stay in force, or the
  --     merged history would count again
  update public.event_resets br set profile_id = t.id
   where br.profile_id = s.id
     and not exists (select 1 from public.event_resets x
                      where x.event_id = br.event_id and x.profile_id = t.id);

  -- 3. profile details: only fill what the new profile has not set
  update public.profiles set
    country_code = coalesce(t.country_code, s.country_code),
    height_cm    = coalesce(t.height_cm, s.height_cm),
    weight_kg    = coalesce(t.weight_kg, s.weight_kg),
    birth_year   = coalesce(t.birth_year, s.birth_year),
    sex          = coalesce(t.sex, s.sex),
    photo_path   = coalesce(t.photo_path, s.photo_path)
  where id = t.id;

  -- 4. phones: old bindings go; the requesting phone binds to the new profile
  delete from public.profile_devices where profile_id = s.id;
  if r.device_id is not null then
    insert into public.profile_devices (device_id, profile_id)
    values (r.device_id, t.id)
    on conflict (device_id) do update
      set profile_id = excluded.profile_id, bound_at = now(), last_used_at = now();
  end if;

  -- 5. the new profile inherits the "self" role if the old one held it
  if s.relation = 'self' then
    update public.profiles set relation = 'other' where id = s.id;
    update public.profiles set relation = 'self' where id = t.id;
  end if;

  -- 6. record, then remove the old profile (the request row survives: FK is set null)
  update public.profile_transfer_requests
     set status = 'approved', decided_by = auth.uid(), decided_at = now(),
         decision_note = left(nullif(btrim(p_note), ''), 300),
         source_days = v_days, source_steps = v_steps
   where id = p_id;
  delete from public.profiles where id = s.id;

  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'transfer.approve', t.id,
          jsonb_build_object('request_id', p_id, 'removed_profile', s.id,
                             'days', v_days, 'steps', v_steps));
  return 'approved';
end;
$$;

revoke all on function public.decide_profile_transfer(uuid, boolean, text) from public, anon;
grant execute on function public.decide_profile_transfer(uuid, boolean, text) to authenticated;
