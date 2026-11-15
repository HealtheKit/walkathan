-- =====================================================================
-- 0013_device_login: a NEW phone needs approval; a known phone does not.
--
--  * account_devices lists the phones a login has been used on.
--  * First phone of a login (or any phone that already uploaded steps for
--    it) is approved automatically: "old phone" logs straight in.
--  * Any other phone starts as PENDING. Only a Super Admin or an organizer
--    of an event the member is on can approve it (same reach as profile
--    transfers). Until then the phone cannot upload steps.
--  * Only a Super Admin may approve their own new phone.
-- =====================================================================

create table if not exists public.account_devices (
  account_id    uuid not null references auth.users (id) on delete cascade,
  device_id     text not null check (char_length(device_id) between 8 and 64),
  label         text check (char_length(label) <= 60),
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  auto_reason   text,                      -- first_device | known_phone
  first_seen    timestamptz not null default now(),
  last_seen     timestamptz not null default now(),
  decided_by    uuid references auth.users (id) on delete set null,
  decided_at    timestamptz,
  decision_note text check (char_length(decision_note) <= 300),
  primary key (account_id, device_id)
);
create index if not exists account_devices_pending_idx on public.account_devices (status) where status = 'pending';
alter table public.account_devices enable row level security;
revoke all on public.account_devices from anon, authenticated;

-- Phones that already uploaded steps for a login are "old phones".
insert into public.account_devices (account_id, device_id, label, status, auto_reason, first_seen, last_seen)
select p.account_id, pd.device_id, 'Known phone', 'approved', 'known_phone', pd.bound_at, pd.last_used_at
  from public.profile_devices pd join public.profiles p on p.id = pd.profile_id
on conflict do nothing;

-- Records a phone and returns its status. Internal: used by the app call
-- below and by step uploads.
create or replace function public.ensure_login_device(p_device_id text, p_label text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_status text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_device_id is null or char_length(p_device_id) not between 8 and 64 then
    raise exception 'invalid device id' using errcode = 'invalid_parameter_value';
  end if;

  update public.account_devices
     set last_seen = now(), label = coalesce(left(nullif(btrim(p_label), ''), 60), label)
   where account_id = auth.uid() and device_id = p_device_id
   returning status into v_status;
  if found then return v_status; end if;

  perform pg_advisory_xact_lock(hashtext(auth.uid()::text));
  if not exists (select 1 from public.account_devices
                  where account_id = auth.uid() and status = 'approved') then
    insert into public.account_devices (account_id, device_id, label, status, auto_reason)
    values (auth.uid(), p_device_id, left(nullif(btrim(p_label), ''), 60), 'approved', 'first_device')
    on conflict do nothing;
    return 'approved';
  end if;
  insert into public.account_devices (account_id, device_id, label, status)
  values (auth.uid(), p_device_id, left(nullif(btrim(p_label), ''), 60), 'pending')
  on conflict do nothing;
  insert into public.admin_audit_log (actor_id, action, details)
  values (auth.uid(), 'device.request', jsonb_build_object('device', right(p_device_id, 6)));
  return 'pending';
end;
$$;

-- The app calls this at every sign-in. p_retry asks again after a rejection.
create or replace function public.register_login_device(
  p_device_id text, p_label text default null, p_retry boolean default false
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_status text;
begin
  v_status := public.ensure_login_device(p_device_id, p_label);
  if v_status = 'rejected' and p_retry then
    update public.account_devices
       set status = 'pending', decided_by = null, decided_at = null, decision_note = null
     where account_id = auth.uid() and device_id = p_device_id;
    v_status := 'pending';
  end if;
  return jsonb_build_object(
    'status', v_status,
    'note', (select decision_note from public.account_devices
              where account_id = auth.uid() and device_id = p_device_id));
end;
$$;

-- ---------- reviewers ----------
create or replace function public.review_device_requests(p_status text default 'pending')
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_transfer_reviewer() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'account_id', d.account_id, 'device_id', d.device_id, 'email', u.email,
             'label', coalesce(d.label, 'Phone'), 'device_tail', right(d.device_id, 4),
             'status', d.status, 'requested_at', d.first_seen, 'decided_at', d.decided_at,
             'decision_note', d.decision_note,
             'own_request', d.account_id = auth.uid(),
             'other_phones', (select count(*) from public.account_devices o
                               where o.account_id = d.account_id and o.status = 'approved'),
             'last_other_use', (select max(o.last_seen) from public.account_devices o
                                 where o.account_id = d.account_id and o.status = 'approved'
                                   and o.device_id <> d.device_id))
           order by d.first_seen desc)
      from public.account_devices d join auth.users u on u.id = d.account_id
     where (p_status is null or d.status = p_status)
       and d.auto_reason is null
       and public.can_review_transfer(d.account_id)), '[]'::jsonb);
end;
$$;

create or replace function public.decide_device(
  p_account uuid, p_device_id text, p_approve boolean, p_note text default null
) returns text
language plpgsql security definer set search_path = ''
as $$
declare d public.account_devices%rowtype;
begin
  if not public.is_transfer_reviewer() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  if not public.can_review_transfer(p_account) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  select * into d from public.account_devices
   where account_id = p_account and device_id = p_device_id for update;
  if not found then return 'not_found'; end if;
  if d.status <> 'pending' then return 'already_' || d.status; end if;
  if p_account = auth.uid() and p_approve and not public.is_platform_admin() then
    raise exception 'you cannot approve your own phone' using errcode = 'insufficient_privilege';
  end if;
  update public.account_devices
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(),
         decision_note = left(nullif(btrim(p_note), ''), 300)
   where account_id = p_account and device_id = p_device_id;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), case when p_approve then 'device.approve' else 'device.reject' end, p_account,
          jsonb_build_object('device', right(p_device_id, 6)));
  return case when p_approve then 'approved' else 'rejected' end;
end;
$$;

-- profile transfers + new phones waiting for this reviewer
create or replace function public.pending_approval_count()
returns int
language sql stable security definer set search_path = ''
as $$
  select case when public.is_transfer_reviewer() then
    (select count(*)::int from public.profile_transfer_requests r
      where r.status = 'pending' and public.can_review_transfer(r.account_id))
    + (select count(*)::int from public.account_devices d
        where d.status = 'pending' and public.can_review_transfer(d.account_id))
    else 0 end;
$$;

revoke all on function
  public.ensure_login_device(text, text), public.register_login_device(text, text, boolean),
  public.review_device_requests(text), public.decide_device(uuid, text, boolean, text),
  public.pending_approval_count() from public, anon;
grant execute on function
  public.register_login_device(text, text, boolean), public.review_device_requests(text),
  public.decide_device(uuid, text, boolean, text), public.pending_approval_count()
  to authenticated;
-- ensure_login_device is internal.

-- ---------- uploads from an unapproved phone are refused (replaces 0010's) ----------
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
