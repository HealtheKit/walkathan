-- =====================================================================
-- 0010_scoring: event scoring, hourly steps, staff roles, data quality,
-- audited corrections, participant management, announcements, rewards.
--
-- Decisions (owner):
--  * Steps per HOUR are stored so "walks at a similar time each day" can be
--    measured (whatever that time is).
--  * Men's / women's boards use profiles.sex; profiles without it appear
--    only on the overall board.
--  * Admin corrections (exclude a day, cap a day) are allowed for staff with
--    an audit trail. Participants still can never enter steps.
--  * Roles: Super Admin (everything), organizer (events, participants,
--    messages, rewards), verifier (step data), viewer (read only).
--  * No age bands, no push notifications, no virtual routes for now.
-- =====================================================================

-- ---------- hourly steps ----------
alter table public.step_day_sources add column if not exists hours int[];
alter table public.step_days        add column if not exists hours int[];

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
  insert into public.step_days (profile_id, local_date, steps, distance_m, kcal, floors, source, tz, updated_at, hours)
  values (p_profile_id, p_date, r.steps, r.distance_m, r.kcal, r.floors, r.source, r.tz, now(), r.hours)
  on conflict (profile_id, local_date) do update
    set steps = excluded.steps, distance_m = excluded.distance_m, kcal = excluded.kcal,
        floors = excluded.floors, source = excluded.source, tz = excluded.tz,
        updated_at = excluded.updated_at, hours = excluded.hours;
end;
$$;
revoke all on function public.recompute_step_day(uuid, date) from public, anon, authenticated;

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
      v_hours  := case when jsonb_typeof(v_item -> 'hours') = 'array'
                       then array(select (h #>> '{}')::int from jsonb_array_elements(v_item -> 'hours') h)
                  end;
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
        (profile_id, local_date, source, steps, distance_m, kcal, floors, tz, observed_at, updated_at, hours)
      values (p_profile_id, v_date, v_src, v_steps, v_dist, v_kcal, v_floors, v_tz, v_obs, now(), v_hours)
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
            hours      = case when (s.source = 'health_store' and excluded.observed_at >= s.observed_at)
                                or (s.source <> 'health_store' and excluded.steps >= s.steps)
                              then coalesce(excluded.hours, s.hours) else s.hours end,
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


-- ---------- staff roles ----------
create table if not exists public.platform_staff (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  role       text not null check (role in ('organizer', 'verifier', 'viewer')),
  granted_by uuid references auth.users (id) on delete set null,
  granted_at timestamptz not null default now()
);
alter table public.platform_staff enable row level security;
revoke all on public.platform_staff from anon, authenticated;

create or replace function public.staff_role()
returns text
language sql stable security definer set search_path = ''
as $$
  select case when exists (select 1 from public.platform_admins where user_id = auth.uid()) then 'super'
              else (select role from public.platform_staff where user_id = auth.uid()) end;
$$;

-- p_action: manage | verify | view
create or replace function public.staff_can(p_action text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select case p_action
           when 'manage' then public.staff_role() in ('super', 'organizer')
           when 'verify' then public.staff_role() in ('super', 'verifier')
           when 'view'   then public.staff_role() is not null
           else false end;
$$;
grant execute on function public.staff_role(), public.staff_can(text) to authenticated;
revoke all on function public.staff_role(), public.staff_can(text) from anon;

create or replace function public.require_staff(p_action text)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not coalesce(public.staff_can(p_action), false) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
end;
$$;
revoke all on function public.require_staff(text) from public, anon, authenticated;

create or replace function public.admin_set_staff(p_email text, p_role text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid;
begin
  if public.staff_role() is distinct from 'super' then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  select id into v_uid from auth.users where lower(email) = lower(btrim(p_email));
  if v_uid is null then return 'not_found'; end if;
  if p_role is null then
    delete from public.platform_staff where user_id = v_uid;
  elsif p_role in ('organizer', 'verifier', 'viewer') then
    insert into public.platform_staff (user_id, role, granted_by) values (v_uid, p_role, auth.uid())
    on conflict (user_id) do update set role = excluded.role, granted_by = excluded.granted_by, granted_at = now();
  else
    raise exception 'invalid role' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'staff.set', v_uid, jsonb_build_object('role', p_role));
  return 'ok';
end;
$$;

create or replace function public.admin_list_staff()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.staff_role() is distinct from 'super' then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('email', u.email, 'role', s.role) order by u.email)
                     from public.platform_staff s join auth.users u on u.id = s.user_id), '[]'::jsonb);
end;
$$;

-- ---------- event configuration and lifecycle ----------
alter table public.events
  add column if not exists status text not null default 'published'
      check (status in ('draft', 'published', 'paused', 'cancelled')),
  add column if not exists daily_cap int check (daily_cap between 1000 and 100000),
  add column if not exists daily_target int not null default 8000 check (daily_target between 1000 and 100000),
  add column if not exists reward_min_steps bigint check (reward_min_steps >= 0),
  add column if not exists reward_min_active_pct int check (reward_min_active_pct between 0 and 100),
  add column if not exists show_gender_boards boolean not null default true;

alter table public.event_accounts
  add column if not exists status text not null default 'active'
      check (status in ('active', 'removed', 'blocked'));

-- members see published / paused events they are actively on
drop policy if exists "see events you are on" on public.events;
create policy "see events you are on" on public.events
  for select to authenticated
  using (public.staff_can('view')
         or (status <> 'draft'
             and exists (select 1 from public.event_accounts ea
                          where ea.event_id = events.id and ea.account_id = auth.uid()
                            and ea.status = 'active')));

create or replace function public.can_see_event(p_event uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.staff_can('view')
      or exists (select 1 from public.events e join public.event_accounts ea on ea.event_id = e.id
                  where e.id = p_event and e.status <> 'draft'
                    and ea.account_id = auth.uid() and ea.status = 'active');
$$;
revoke all on function public.can_see_event(uuid) from public, anon, authenticated;

-- organizers manage events too (previously Super Admin only)
create or replace function public.admin_create_event(
  p_name text, p_starts_on date, p_ends_on date, p_description text default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  perform public.require_staff('manage');
  insert into public.events (name, description, starts_on, ends_on, created_by, status)
  values (btrim(p_name), nullif(btrim(p_description), ''), p_starts_on, p_ends_on, auth.uid(), 'draft')
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_delete_event(p_event_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('manage');
  delete from public.events where id = p_event_id;
end;
$$;

drop function if exists public.admin_list_events();
create or replace function public.admin_list_events()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.require_staff('view');
  return coalesce((select jsonb_agg(to_jsonb(e) || jsonb_build_object(
             'member_count', (select count(*) from public.event_accounts ea
                               where ea.event_id = e.id and ea.status = 'active'))
           order by e.starts_on desc, e.created_at desc)
      from public.events e), '[]'::jsonb);
end;
$$;

create or replace function public.admin_update_event(
  p_event uuid, p_name text default null, p_description text default null,
  p_starts_on date default null, p_ends_on date default null,
  p_status text default null, p_daily_cap int default null, p_clear_cap boolean default false,
  p_daily_target int default null, p_reward_min_steps bigint default null,
  p_reward_min_active_pct int default null, p_show_gender_boards boolean default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('manage');
  update public.events set
    name        = coalesce(nullif(btrim(p_name), ''), name),
    description = coalesce(p_description, description),
    starts_on   = coalesce(p_starts_on, starts_on),
    ends_on     = coalesce(p_ends_on, ends_on),
    status      = coalesce(p_status, status),
    daily_cap   = case when p_clear_cap then null else coalesce(p_daily_cap, daily_cap) end,
    daily_target = coalesce(p_daily_target, daily_target),
    reward_min_steps = coalesce(p_reward_min_steps, reward_min_steps),
    reward_min_active_pct = coalesce(p_reward_min_active_pct, reward_min_active_pct),
    show_gender_boards = coalesce(p_show_gender_boards, show_gender_boards)
  where id = p_event;
  insert into public.admin_audit_log (actor_id, action, details)
  values (auth.uid(), 'event.update', jsonb_build_object('event_id', p_event, 'status', p_status));
end;
$$;

drop function if exists public.admin_event_roster(uuid);
create or replace function public.admin_event_roster(p_event_id uuid)
returns table (account_id uuid, email text, added_at timestamptz, profile_count bigint,
               has_signed_in boolean, status text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.require_staff('view');
  return query
    select u.id, u.email::text, ea.added_at,
           (select count(*) from public.profiles p where p.account_id = u.id),
           u.last_sign_in_at is not null, ea.status
      from public.event_accounts ea join auth.users u on u.id = ea.account_id
     where ea.event_id = p_event_id order by u.email;
end;
$$;

create or replace function public.admin_remove_event_account(p_event_id uuid, p_account_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('manage');
  delete from public.event_accounts where event_id = p_event_id and account_id = p_account_id;
end;
$$;

-- active (reinstate) | removed | blocked
create or replace function public.admin_set_participant_status(p_event uuid, p_account uuid, p_status text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('manage');
  update public.event_accounts set status = p_status where event_id = p_event and account_id = p_account;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'participant.status', p_account, jsonb_build_object('event_id', p_event, 'status', p_status));
end;
$$;

-- Reassign an account from one event to another.
create or replace function public.admin_move_participant(p_from uuid, p_to uuid, p_account uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('manage');
  delete from public.event_accounts where event_id = p_from and account_id = p_account;
  insert into public.event_accounts (event_id, account_id) values (p_to, p_account)
  on conflict (event_id, account_id) do update set status = 'active';
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'participant.move', p_account, jsonb_build_object('from', p_from, 'to', p_to));
end;
$$;

create or replace function public.admin_set_profile_sex(p_profile uuid, p_sex text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('manage');
  update public.profiles set sex = p_sex where id = p_profile;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'profile.sex', p_profile, jsonb_build_object('sex', p_sex));
end;
$$;

-- ---------- corrections (audited) ----------
create table if not exists public.step_corrections (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  local_date date not null,
  action     text not null check (action in ('exclude', 'cap')),
  cap_steps  int check (cap_steps between 0 and 100000),
  reason     text not null check (char_length(btrim(reason)) between 3 and 300),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (profile_id, local_date),
  check (action <> 'cap' or cap_steps is not null)
);
alter table public.step_corrections enable row level security;
revoke all on public.step_corrections from anon, authenticated;

alter table public.profiles add column if not exists resync_requested_at timestamptz;

-- p_action: exclude | cap | clear
create or replace function public.admin_correct_day(
  p_profile uuid, p_date date, p_action text, p_cap int default null, p_reason text default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('verify');
  if p_action = 'clear' then
    delete from public.step_corrections where profile_id = p_profile and local_date = p_date;
  else
    insert into public.step_corrections (profile_id, local_date, action, cap_steps, reason, created_by)
    values (p_profile, p_date, p_action, p_cap, p_reason, auth.uid())
    on conflict (profile_id, local_date) do update
      set action = excluded.action, cap_steps = excluded.cap_steps, reason = excluded.reason,
          created_by = excluded.created_by, created_at = now();
  end if;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'steps.correct', p_profile,
          jsonb_build_object('date', p_date, 'action', p_action, 'cap', p_cap, 'reason', p_reason));
end;
$$;

-- Asks the participant's phone to re-upload its history on its next sync.
create or replace function public.admin_request_resync(p_profile uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('verify');
  update public.profiles set resync_requested_at = now() where id = p_profile;
  insert into public.admin_audit_log (actor_id, action, target_id)
  values (auth.uid(), 'steps.resync', p_profile);
end;
$$;

-- ---------- effective steps for an event ----------
-- One row per (profile, day) inside the event for active roster members,
-- with corrections and the event's daily cap applied.
create or replace function public.event_days(p_event uuid, p_to date)
returns table (profile_id uuid, local_date date, steps int, distance_m int, kcal int,
               hours int[], raw_steps int, corrected text)
language sql stable security definer set search_path = ''
as $$
  select sd.profile_id, sd.local_date,
         least(case c.action when 'exclude' then 0
                             when 'cap' then least(sd.steps, c.cap_steps)
                             else sd.steps end,
               coalesce(e.daily_cap, 100000)),
         sd.distance_m, sd.kcal, sd.hours, sd.steps, c.action
    from public.events e
    join public.event_accounts ea on ea.event_id = e.id and ea.status = 'active'
    join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
    join public.step_days sd on sd.profile_id = p.id
         and sd.local_date between e.starts_on and least(e.ends_on, p_to)
    left join public.step_corrections c on c.profile_id = sd.profile_id and c.local_date = sd.local_date
   where e.id = p_event;
$$;
revoke all on function public.event_days(uuid, date) from public, anon, authenticated;

-- ---------- the event board (metrics + men / women) ----------
drop function if exists public.event_board(uuid, text, date, int);
create or replace function public.event_board(
  p_event_id uuid, p_period text default 'event', p_local_date date default null,
  p_limit int default 50, p_metric text default 'steps', p_sex text default null
) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  e       public.events%rowtype;
  v_today date := public.clamp_local_date(p_local_date);
  v_from  date; v_to date; v_days int;
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_result jsonb;
begin
  if auth.uid() is null or not public.can_see_event(p_event_id) then
    raise exception 'event not available' using errcode = 'insufficient_privilege';
  end if;
  if p_period not in ('event', 'week', 'day')
     or p_metric not in ('steps', 'avg', 'distance', 'active_days')
     or (p_sex is not null and p_sex not in ('male', 'female')) then
    raise exception 'invalid parameters' using errcode = 'invalid_parameter_value';
  end if;
  select * into e from public.events where id = p_event_id;

  if p_period = 'day' then v_from := v_today; v_to := v_today;
  elsif p_period = 'week' then v_from := date_trunc('week', v_today)::date; v_to := v_from + 6;
  else v_from := e.starts_on; v_to := e.ends_on; end if;
  v_from := greatest(v_from, e.starts_on);
  v_to   := least(v_to, e.ends_on, v_today);
  v_days := greatest(v_to - v_from + 1, 1);

  with people as (
    select p.id, public.profile_label(p.display_name) as name, p.account_id = auth.uid() as mine
      from public.event_accounts ea
      join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
     where ea.event_id = p_event_id and ea.status = 'active'
       and (p_sex is null or p.sex = p_sex)
  ),
  agg as (
    select pe.id, pe.name, pe.mine,
           coalesce(sum(d.steps), 0)::bigint as steps,
           coalesce(sum(d.distance_m), 0)::bigint as distance_m,
           count(d.local_date) filter (where d.steps > 0) as active_days
      from people pe
      left join public.event_days(p_event_id, v_to) d
             on d.profile_id = pe.id and d.local_date between v_from and v_to
     group by pe.id, pe.name, pe.mine
  ),
  scored as (
    select a.*, (a.steps / v_days)::bigint as avg,
           case p_metric when 'steps' then a.steps
                         when 'avg' then a.steps / v_days
                         when 'distance' then a.distance_m
                         else a.active_days end as value
      from agg a
  ),
  ranked as (
    select s.*, rank() over (order by s.value desc) as rnk,
           lag(s.value) over (order by s.value desc) as above
      from scored s
  ),
  shaped as (
    select r.rnk, r.name, r.mine, jsonb_build_object(
             'rank', r.rnk, 'profile_id', r.id, 'name', r.name, 'mine', r.mine,
             'steps', r.steps, 'distance_m', r.distance_m, 'active_days', r.active_days,
             'avg', r.avg, 'value', r.value,
             -- gap to the next rank up (0 for the leader)
             'gap', greatest(coalesce((select min(x.value) from ranked x where x.value > r.value), r.value) - r.value, 0),
             'top_pct', ceil(100.0 * r.rnk / greatest((select count(*) from ranked), 1))) as x
      from ranked r
  )
  select jsonb_build_object(
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'starts_on', e.starts_on,
                                'ends_on', e.ends_on, 'status', e.status,
                                'daily_target', e.daily_target, 'show_gender_boards', e.show_gender_boards),
    'period', p_period, 'metric', p_metric, 'sex', p_sex,
    'from', v_from, 'to', v_to, 'today', v_today,
    'walkers', (select count(*) from ranked),
    'active_walkers', (select count(*) from ranked where steps > 0),
    'total_steps', (select coalesce(sum(steps), 0) from ranked),
    'total_distance_m', (select coalesce(sum(distance_m), 0) from ranked),
    'average_value', (select coalesce(round(avg(value)), 0) from ranked),
    'rows', coalesce((select jsonb_agg(q.x order by q.rnk, q.name)
                        from (select * from shaped order by rnk, name limit v_limit) q), '[]'::jsonb),
    'mine', coalesce((select jsonb_agg(s.x order by s.rnk, s.name) from shaped s where s.mine), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

-- ---------- a participant's own event data ----------
create or replace function public.my_event_stats(p_me uuid, p_event uuid, p_local_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare e public.events%rowtype; v_today date := public.clamp_local_date(p_local_date);
begin
  perform public.assert_my_profile(p_me);
  if not public.can_see_event(p_event) then
    raise exception 'event not available' using errcode = 'insufficient_privilege';
  end if;
  select * into e from public.events where id = p_event;
  return jsonb_build_object(
    'event', jsonb_build_object('id', e.id, 'name', e.name, 'starts_on', e.starts_on,
               'ends_on', e.ends_on, 'status', e.status, 'daily_target', e.daily_target,
               'daily_cap', e.daily_cap, 'reward_min_steps', e.reward_min_steps,
               'reward_min_active_pct', e.reward_min_active_pct),
    'today', v_today,
    'days', coalesce((select jsonb_agg(jsonb_build_object(
               'date', d.local_date, 'steps', d.steps, 'distance_m', d.distance_m,
               'kcal', d.kcal, 'hours', to_jsonb(d.hours)) order by d.local_date)
             from public.event_days(p_event, v_today) d where d.profile_id = p_me), '[]'::jsonb),
    'reward', (select jsonb_build_object('award', r.award, 'status', r.status)
                 from public.event_rewards r where r.event_id = p_event and r.profile_id = p_me),
    'announcements', coalesce((select jsonb_agg(jsonb_build_object(
               'title', a.title, 'body', a.body, 'at', a.created_at) order by a.created_at desc)
             from (select * from public.event_announcements a
                    where a.event_id = p_event
                      and (a.audience = 'all'
                           or a.audience = (select sex from public.profiles where id = p_me))
                    order by a.created_at desc limit 10) a), '[]'::jsonb));
end;
$$;

-- ---------- announcements ----------
create table if not exists public.event_announcements (
  id         bigint generated always as identity primary key,
  event_id   uuid not null references public.events (id) on delete cascade,
  audience   text not null default 'all' check (audience in ('all', 'male', 'female')),
  title      text not null check (char_length(btrim(title)) between 2 and 80),
  body       text not null check (char_length(btrim(body)) between 1 and 1000),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.event_announcements enable row level security;
revoke all on public.event_announcements from anon, authenticated;

create or replace function public.admin_post_announcement(p_event uuid, p_audience text, p_title text, p_body text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('manage');
  insert into public.event_announcements (event_id, audience, title, body, created_by)
  values (p_event, coalesce(p_audience, 'all'), btrim(p_title), btrim(p_body), auth.uid());
end;
$$;

-- ---------- rewards ----------
create table if not exists public.event_rewards (
  event_id   uuid not null references public.events (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  award      text not null check (char_length(btrim(award)) between 2 and 80),
  status     text not null default 'selected' check (status in ('selected', 'awarded', 'delivered')),
  updated_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (event_id, profile_id)
);
alter table public.event_rewards enable row level security;
revoke all on public.event_rewards from anon, authenticated;

-- p_award null = remove the reward
create or replace function public.admin_set_reward(p_event uuid, p_profile uuid, p_award text, p_status text default 'selected')
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_staff('manage');
  if p_award is null then
    delete from public.event_rewards where event_id = p_event and profile_id = p_profile;
  else
    insert into public.event_rewards (event_id, profile_id, award, status, updated_by)
    values (p_event, p_profile, btrim(p_award), p_status, auth.uid())
    on conflict (event_id, profile_id) do update
      set award = excluded.award, status = excluded.status, updated_by = excluded.updated_by, updated_at = now();
  end if;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'reward.set', p_profile, jsonb_build_object('event_id', p_event, 'award', p_award, 'status', p_status));
end;
$$;

-- ---------- organizer / admin views ----------
-- One row per participant profile with scoring metrics and quality flags.
create or replace function public.admin_participants(p_event uuid, p_local_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  e public.events%rowtype;
  v_today date := public.clamp_local_date(p_local_date);
  v_to date; v_days int;
begin
  perform public.require_staff('view');
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
               where r.event_id = p_event and r.profile_id = pe.id) as reward
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
  perform public.require_staff('view');
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
  perform public.require_staff('view');
  select * into e from public.events where id = p_event;
  return coalesce((select jsonb_agg(jsonb_build_object(
             'date', sd.local_date, 'raw_steps', sd.steps, 'source', sd.source,
             'hours', to_jsonb(sd.hours), 'updated_at', sd.updated_at,
             'correction', c.action, 'cap_steps', c.cap_steps, 'reason', c.reason)
           order by sd.local_date desc)
      from public.step_days sd
      left join public.step_corrections c on c.profile_id = sd.profile_id and c.local_date = sd.local_date
     where sd.profile_id = p_profile and sd.local_date between e.starts_on and e.ends_on), '[]'::jsonb);
end;
$$;

-- ---------- grants ----------
revoke all on function
  public.admin_set_staff(text, text), public.admin_list_staff(), public.admin_list_events(),
  public.admin_update_event(uuid, text, text, date, date, text, int, boolean, int, bigint, int, boolean),
  public.admin_event_roster(uuid), public.admin_set_participant_status(uuid, uuid, text),
  public.admin_move_participant(uuid, uuid, uuid), public.admin_set_profile_sex(uuid, text),
  public.admin_correct_day(uuid, date, text, int, text), public.admin_request_resync(uuid),
  public.event_board(uuid, text, date, int, text, text), public.my_event_stats(uuid, uuid, date),
  public.admin_post_announcement(uuid, text, text, text), public.admin_set_reward(uuid, uuid, text, text),
  public.admin_participants(uuid, date), public.admin_event_overview(uuid, date),
  public.admin_participant_days(uuid, uuid)
  from public, anon;
grant execute on function
  public.admin_set_staff(text, text), public.admin_list_staff(), public.admin_list_events(),
  public.admin_update_event(uuid, text, text, date, date, text, int, boolean, int, bigint, int, boolean),
  public.admin_event_roster(uuid), public.admin_set_participant_status(uuid, uuid, text),
  public.admin_move_participant(uuid, uuid, uuid), public.admin_set_profile_sex(uuid, text),
  public.admin_correct_day(uuid, date, text, int, text), public.admin_request_resync(uuid),
  public.event_board(uuid, text, date, int, text, text), public.my_event_stats(uuid, uuid, date),
  public.admin_post_announcement(uuid, text, text, text), public.admin_set_reward(uuid, uuid, text, text),
  public.admin_participants(uuid, date), public.admin_event_overview(uuid, date),
  public.admin_participant_days(uuid, uuid)
  to authenticated;
