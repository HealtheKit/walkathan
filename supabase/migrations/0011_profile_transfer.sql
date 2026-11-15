-- =====================================================================
-- 0011_profile_transfer: move a walker's data to the profile on a NEW phone.
--
--  * A member who got a new phone asks to "replace" their OLD profile with
--    the profile now on the new phone. The OLD profile's step history is
--    merged into the NEW profile and the OLD profile is then removed.
--  * Nothing happens until a Super Admin or an ORGANIZER OF AN EVENT the
--    member is on approves it. Rejecting/cancelling changes nothing.
--  * Organizers are per event and there can be several per event
--    (event_organizers). They only review members on their own events.
--  * Only a Super Admin may approve their own request.
--  * Everything is audited in admin_audit_log.
-- Not moved (removed with the old profile): friendships and group
-- memberships, which belong to the old profile identity.
-- =====================================================================

-- ---------- per-event organizers (many per event) ----------
create table if not exists public.event_organizers (
  event_id   uuid not null references public.events (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  granted_by uuid references auth.users (id) on delete set null,
  granted_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index if not exists event_organizers_user_idx on public.event_organizers (user_id);
alter table public.event_organizers enable row level security;
revoke all on public.event_organizers from anon, authenticated;

create or replace function public.is_event_organizer(p_event uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.event_organizers
                  where event_id = p_event and user_id = auth.uid());
$$;

-- Super Admin, or an existing organizer of that event, adds another one.
create or replace function public.add_event_organizer(p_event uuid, p_email text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid;
begin
  if not (public.is_platform_admin() or public.is_event_organizer(p_event)) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  select id into v_uid from auth.users where lower(email) = lower(btrim(p_email));
  if v_uid is null then return 'not_found'; end if;
  insert into public.event_organizers (event_id, user_id, granted_by)
  values (p_event, v_uid, auth.uid())
  on conflict do nothing;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'organizer.add', v_uid, jsonb_build_object('event_id', p_event));
  return 'ok';
end;
$$;

create or replace function public.remove_event_organizer(p_event uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (public.is_platform_admin() or public.is_event_organizer(p_event)) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  delete from public.event_organizers where event_id = p_event and user_id = p_user;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'organizer.remove', p_user, jsonb_build_object('event_id', p_event));
end;
$$;

create or replace function public.list_event_organizers(p_event uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.staff_can('view') or public.is_event_organizer(p_event)) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('user_id', o.user_id, 'email', u.email,
                                        'granted_at', o.granted_at) order by u.email)
      from public.event_organizers o join auth.users u on u.id = o.user_id
     where o.event_id = p_event), '[]'::jsonb);
end;
$$;

-- ---------- transfer requests ----------
create table if not exists public.profile_transfer_requests (
  id                uuid primary key default gen_random_uuid(),
  account_id        uuid not null references auth.users (id) on delete cascade,
  -- OLD phone's profile: its data moves, then it is removed.
  -- set null (not cascade) so the request stays as history after removal.
  source_profile_id uuid references public.profiles (id) on delete set null,
  -- NEW phone's profile: receives the data and survives.
  target_profile_id uuid references public.profiles (id) on delete set null,
  device_id         text check (char_length(device_id) between 8 and 64),
  reason            text not null check (char_length(btrim(reason)) between 5 and 300),
  status            text not null default 'pending'
                      check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  requested_at      timestamptz not null default now(),
  decided_by        uuid references auth.users (id) on delete set null,
  decided_at        timestamptz,
  decision_note     text check (char_length(decision_note) <= 300),
  -- kept so history reads well after the old profile is gone
  source_name       text,
  target_name       text,
  source_steps      bigint,
  source_days       int,
  check (source_profile_id is distinct from target_profile_id)
);
-- One open request per old profile.
create unique index if not exists profile_transfer_one_pending
  on public.profile_transfer_requests (source_profile_id) where status = 'pending';
create index if not exists profile_transfer_account_idx
  on public.profile_transfer_requests (account_id, requested_at desc);
alter table public.profile_transfer_requests enable row level security;
revoke all on public.profile_transfer_requests from anon, authenticated;
-- all access is through the functions below

-- Can the caller review requests from this account?
create or replace function public.can_review_transfer(p_account uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.is_platform_admin()
      or exists (select 1
                   from public.event_organizers eo
                   join public.event_accounts ea on ea.event_id = eo.event_id
                  where eo.user_id = auth.uid()
                    and ea.account_id = p_account
                    and ea.status = 'active');
$$;

-- Does the caller review transfers at all? (shows/hides the staff screen)
create or replace function public.is_transfer_reviewer()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.is_platform_admin()
      or exists (select 1 from public.event_organizers where user_id = auth.uid());
$$;

create or replace function public.request_profile_transfer(
  p_source uuid, p_target uuid, p_device_id text, p_reason text
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_sn text;
  v_tn text;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  if p_source = p_target then
    raise exception 'pick two different profiles' using errcode = 'invalid_parameter_value';
  end if;
  select display_name into v_sn from public.profiles
   where id = p_source and account_id = auth.uid();
  if not found then
    raise exception 'not your profile' using errcode = 'insufficient_privilege';
  end if;
  select display_name into v_tn from public.profiles
   where id = p_target and account_id = auth.uid();
  if not found then
    raise exception 'not your profile' using errcode = 'insufficient_privilege';
  end if;
  if p_device_id is not null and char_length(p_device_id) not between 8 and 64 then
    raise exception 'invalid device id' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.profile_transfer_requests
    (account_id, source_profile_id, target_profile_id, device_id, reason, source_name, target_name)
  values (auth.uid(), p_source, p_target, p_device_id, btrim(p_reason), v_sn, v_tn)
  returning id into v_id;

  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'transfer.request', p_source,
          jsonb_build_object('request_id', v_id, 'target', p_target));
  return v_id;
exception when unique_violation then
  raise exception 'a transfer for this profile is already waiting for approval'
    using errcode = 'check_violation';
end;
$$;

create or replace function public.cancel_profile_transfer(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.profile_transfer_requests
     set status = 'cancelled', decided_at = now()
   where id = p_id and account_id = auth.uid() and status = 'pending';
  if not found then
    raise exception 'no pending request found' using errcode = 'no_data_found';
  end if;
end;
$$;

-- The member's own requests, newest first.
create or replace function public.my_profile_transfers()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'source_profile_id', r.source_profile_id,
           'target_profile_id', r.target_profile_id,
           'source_name', r.source_name, 'target_name', r.target_name,
           'reason', r.reason, 'status', r.status,
           'requested_at', r.requested_at, 'decided_at', r.decided_at,
           'decision_note', r.decision_note) order by r.requested_at desc), '[]'::jsonb)
    from public.profile_transfer_requests r
   where r.account_id = auth.uid();
$$;

-- What a reviewer sees: enough to judge the request, never daily detail.
create or replace function public.review_profile_transfers(p_status text default 'pending')
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_transfer_reviewer() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'email', u.email, 'reason', r.reason, 'status', r.status,
             'requested_at', r.requested_at, 'decided_at', r.decided_at,
             'decision_note', r.decision_note,
             'source_name', r.source_name, 'target_name', r.target_name,
             'own_request', r.account_id = auth.uid(),
             'source_days', case when r.status = 'pending'
                  then (select count(*) from public.step_days d where d.profile_id = r.source_profile_id)
                  else r.source_days end,
             'source_steps', case when r.status = 'pending'
                  then (select coalesce(sum(steps), 0) from public.step_days d where d.profile_id = r.source_profile_id)
                  else r.source_steps end,
             'target_days', (select count(*) from public.step_days d where d.profile_id = r.target_profile_id),
             'target_steps', (select coalesce(sum(steps), 0) from public.step_days d where d.profile_id = r.target_profile_id),
             'source_last_upload', (select max(last_used_at) from public.profile_devices pd
                                     where pd.profile_id = r.source_profile_id)
           ) order by r.requested_at desc)
      from public.profile_transfer_requests r
      join auth.users u on u.id = r.account_id
     where (p_status is null or r.status = p_status)
       and public.can_review_transfer(r.account_id)), '[]'::jsonb);
end;
$$;

create or replace function public.pending_transfer_count()
returns int
language sql stable security definer set search_path = ''
as $$
  select case when public.is_transfer_reviewer() then
    (select count(*)::int from public.profile_transfer_requests r
      where r.status = 'pending' and public.can_review_transfer(r.account_id))
    else 0 end;
$$;

-- Approve: merge the old profile into the new one and remove the old one.
-- Reject: nothing changes except the request.
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

-- ---------- grants ----------
revoke all on function
  public.is_event_organizer(uuid), public.add_event_organizer(uuid, text),
  public.remove_event_organizer(uuid, uuid), public.list_event_organizers(uuid),
  public.can_review_transfer(uuid), public.is_transfer_reviewer(),
  public.request_profile_transfer(uuid, uuid, text, text),
  public.cancel_profile_transfer(uuid), public.my_profile_transfers(),
  public.review_profile_transfers(text), public.pending_transfer_count(),
  public.decide_profile_transfer(uuid, boolean, text)
  from public, anon;
grant execute on function
  public.is_event_organizer(uuid), public.add_event_organizer(uuid, text),
  public.remove_event_organizer(uuid, uuid), public.list_event_organizers(uuid),
  public.is_transfer_reviewer(),
  public.request_profile_transfer(uuid, uuid, text, text),
  public.cancel_profile_transfer(uuid), public.my_profile_transfers(),
  public.review_profile_transfers(text), public.pending_transfer_count(),
  public.decide_profile_transfer(uuid, boolean, text)
  to authenticated;
-- can_review_transfer is internal (called inside the functions above).
