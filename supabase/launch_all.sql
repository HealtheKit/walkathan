-- =====================================================================
-- Walkathon launch setup: ONE paste for the Supabase SQL Editor.
-- GENERATED from supabase/migrations/* and supabase/ops/seed_super_admin.sql
-- (edit those, then regenerate by concatenating the four files in this order).
--
-- WHAT IT DOES, in order:
--   1. 0001 foundation   2. 0003 steps   3. 0004 rest days
--   4. 0005 events   5. 0002 DROPS old v1 tables   6. installs ops.seed_super_admin()
--
-- PERMANENT: step 5 deletes all old profile and step data. It does NOT
-- delete accounts (that is ops.reset_launch_data, a separate step).
-- It replaces the sign-up trigger, so the OLD app build stops working.
--
-- AFTER IT RUNS:
--   select ops.seed_super_admin('navis@tresundios.com');
-- (create that user first in Authentication > Users > Add user,
--  tick "Auto Confirm User", or run the seed first; it promotes the
--  account as soon as the email is verified.)
-- =====================================================================







-- ################ migrations/0001_foundation.sql ################
-- =====================================================================
-- 0001_foundation: household accounts (1 login -> up to 6 walker profiles),
-- privacy-first RLS, platform admins, member listing, app_config
--
-- Additive: does NOT drop the v1 tables (users, daily_steps). See 0002.
-- DEPLOY ORDER: this migration replaces the signup trigger, so the v1 app
-- (which reads public.users) stops working. Apply it together with the
-- Phase 1 app release and the launch reset, not before.
-- =====================================================================

-- ---------- app_config (public read of the reset epoch only) ----------
create table if not exists public.app_config (
  key   text primary key,
  value jsonb not null
);
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;
grant select on public.app_config to anon, authenticated;
drop policy if exists "read public config" on public.app_config;
create policy "read public config" on public.app_config
  for select to anon, authenticated
  using (key in ('reset_epoch'));

insert into public.app_config (key, value)
values ('reset_epoch', to_jsonb(now()::text))
on conflict (key) do nothing;

-- ---------- platform admins ----------
-- Emails the owner seeds by hand (service role / SQL editor). Clients can
-- never read or write this table.
create table if not exists public.platform_admin_emails (
  email text primary key check (email = lower(email))
);
alter table public.platform_admin_emails enable row level security;
revoke all on public.platform_admin_emails from anon, authenticated;

create table if not exists public.platform_admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);
alter table public.platform_admins enable row level security;
revoke all on public.platform_admins from anon, authenticated;
grant select on public.platform_admins to authenticated;
drop policy if exists "see own admin row" on public.platform_admins;
create policy "see own admin row" on public.platform_admins
  for select to authenticated
  using (user_id = auth.uid());

create or replace function public.is_platform_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;
revoke all on function public.is_platform_admin() from public, anon;
grant execute on function public.is_platform_admin() to authenticated;

-- ---------- profiles (walkers) ----------
-- One login (auth.users row = the "account") owns 1..6 walker profiles:
-- self, spouse, children, other. Steps, goals and leaderboard entries
-- belong to a PROFILE. No email copy: the email lives only in auth.users.
create table if not exists public.profiles (
  id               uuid primary key default gen_random_uuid(),
  account_id       uuid not null references auth.users (id) on delete cascade,
  relation         text not null default 'self'
                     check (relation in ('self', 'spouse', 'child', 'other')),
  display_name     text not null default '' check (char_length(display_name) <= 40),
  photo_path       text,
  country_code     text check (country_code ~ '^[A-Z]{2}$'),
  timezone         text not null default 'UTC' check (char_length(timezone) between 1 and 64),
  locale           text not null default 'en' check (locale in ('en', 'ta', 'hi')),
  height_cm        numeric(5,1) check (height_cm between 50 and 260),
  weight_kg        numeric(5,1) check (weight_kg between 20 and 400),
  birth_year       int check (birth_year between 1900 and 2100),
  sex              text check (sex in ('female', 'male', 'other')),
  daily_goal       int not null default 8000 check (daily_goal between 1000 and 100000),
  steps_visibility text not null default 'private' check (steps_visibility in ('private', 'friends')),
  created_at       timestamptz not null default now(),
  deleted_at       timestamptz
);
create unique index if not exists profiles_one_self_per_account
  on public.profiles (account_id) where relation = 'self';
create index if not exists profiles_account_idx on public.profiles (account_id);

-- Hard cap: at most 6 profiles per account (serialised per account so two
-- concurrent inserts cannot both slip past the limit).
create or replace function public.enforce_profile_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtext(new.account_id::text));
  if (select count(*) from public.profiles where account_id = new.account_id) >= 6 then
    raise exception 'profile limit reached: an account can have at most 6 profiles'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_limit on public.profiles;
create trigger profiles_limit before insert on public.profiles
  for each row execute function public.enforce_profile_limit();

alter table public.profiles enable row level security;

-- Default-deny, then allow exactly what the account owner needs.
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant insert (account_id, relation, display_name, photo_path, country_code, timezone,
              locale, height_cm, weight_kg, birth_year, sex, daily_goal, steps_visibility)
  on public.profiles to authenticated;
-- account_id, relation, deleted_at are NOT updatable by clients.
grant update (display_name, photo_path, country_code, timezone, locale,
              height_cm, weight_kg, birth_year, sex, daily_goal, steps_visibility)
  on public.profiles to authenticated;
grant delete on public.profiles to authenticated;

drop policy if exists "own profiles: read" on public.profiles;
create policy "own profiles: read" on public.profiles
  for select to authenticated using (account_id = auth.uid());

-- 'self' is created by the signup trigger only; clients add the others.
drop policy if exists "own profiles: add" on public.profiles;
create policy "own profiles: add" on public.profiles
  for insert to authenticated
  with check (account_id = auth.uid() and relation <> 'self');

drop policy if exists "own profiles: update" on public.profiles;
create policy "own profiles: update" on public.profiles
  for update to authenticated
  using (account_id = auth.uid()) with check (account_id = auth.uid());

-- The 'self' profile can only go away with the whole account.
drop policy if exists "own profiles: delete non-self" on public.profiles;
create policy "own profiles: delete non-self" on public.profiles
  for delete to authenticated
  using (account_id = auth.uid() and relation <> 'self');
-- Friends/groups reading names and photos is added in Phase 4/5 through
-- functions that check the relationship, not through table access.

-- ---------- signup trigger (replaces the v1 one) ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (account_id, relation, display_name, locale)
  values (
    new.id, 'self',
    left(coalesce(nullif(new.raw_user_meta_data ->> 'name', ''),
                  nullif(new.raw_user_meta_data ->> 'full_name', ''), ''), 40),
    case when new.raw_user_meta_data ->> 'locale' in ('en', 'ta', 'hi')
         then new.raw_user_meta_data ->> 'locale' else 'en' end
  )
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Promote seeded emails to platform admin, but only once the email is VERIFIED.
create or replace function public.sync_platform_admin()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.email_confirmed_at is not null
     and exists (select 1 from public.platform_admin_emails
                 where email = lower(new.email)) then
    insert into public.platform_admins (user_id) values (new.id)
    on conflict do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_admin_sync on auth.users;
create trigger on_auth_user_admin_sync
  after insert or update of email_confirmed_at, email on auth.users
  for each row execute function public.sync_platform_admin();

-- ---------- Super Admin: member listing ----------
-- Super Admins may see who is registered (email, activity, profile count).
-- They cannot see steps or profile details. Create/disable/delete of
-- accounts is done by the admin Edge Function with the service role.
create or replace function public.admin_list_members()
returns table (
  account_id      uuid,
  email           text,
  created_at      timestamptz,
  last_sign_in_at timestamptz,
  profile_count   bigint,
  is_disabled     boolean
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  return query
    select u.id, u.email::text, u.created_at, u.last_sign_in_at,
           (select count(*) from public.profiles p where p.account_id = u.id),
           coalesce(u.banned_until > now(), false)
    from auth.users u
    order by u.created_at desc;
end;
$$;
revoke all on function public.admin_list_members() from public, anon;
grant execute on function public.admin_list_members() to authenticated;

-- ---------- audit log (written by Edge Functions with the service role) ----------
create table if not exists public.admin_audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid,
  action     text not null,
  target_id  uuid,
  details    jsonb not null default '{}'::jsonb,
  at         timestamptz not null default now()
);
alter table public.admin_audit_log enable row level security;
revoke all on public.admin_audit_log from anon, authenticated;
-- Super Admins may read it; nobody can write from a client.
grant select on public.admin_audit_log to authenticated;
drop policy if exists "admins read audit log" on public.admin_audit_log;
create policy "admins read audit log" on public.admin_audit_log
  for select to authenticated using (public.is_platform_admin());

-- ---------- feedback (Help & Feedback screen) ----------
-- Diagnostics must never contain health data; the app sends only app/OS info.
create table if not exists public.feedback (
  id          bigint generated always as identity primary key,
  account_id  uuid not null references auth.users (id) on delete cascade,
  message     text not null check (char_length(message) between 1 and 2000),
  diagnostics jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;
grant insert (account_id, message, diagnostics) on public.feedback to authenticated;
grant select on public.feedback to authenticated;
drop policy if exists "send own feedback" on public.feedback;
create policy "send own feedback" on public.feedback
  for insert to authenticated with check (account_id = auth.uid());
drop policy if exists "admins read feedback" on public.feedback;
create policy "admins read feedback" on public.feedback
  for select to authenticated using (public.is_platform_admin());


-- ################ migrations/0003_steps.sql ################
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


-- ################ migrations/0004_rest_days.sql ################
-- =====================================================================
-- 0004_rest_days: Rest Days keep a streak alive without walking.
--
-- Rules (enforced here, not just in the app):
--  * At most 2 rest days per Monday-Sunday week per profile.
--  * A rest day can only be set for yesterday or later (1 day of slack for
--    time zones), up to 8 days ahead. No back-dating to repair old streaks.
--  * Only the owning account can read, add or remove them.
-- Streaks, records and achievements are derived from step_days + rest_days
-- in the app (pure, tested logic); nothing else is stored in Phase 3.
-- =====================================================================
create table if not exists public.rest_days (
  profile_id uuid not null references public.profiles (id) on delete cascade,
  local_date date not null,
  created_at timestamptz not null default now(),
  primary key (profile_id, local_date)
);
alter table public.rest_days enable row level security;
revoke all on public.rest_days from anon, authenticated;
grant select, delete on public.rest_days to authenticated;
grant insert (profile_id, local_date) on public.rest_days to authenticated;

drop policy if exists "own rest days: read" on public.rest_days;
create policy "own rest days: read" on public.rest_days
  for select to authenticated
  using (exists (select 1 from public.profiles p
                 where p.id = rest_days.profile_id and p.account_id = auth.uid()));

drop policy if exists "own rest days: add" on public.rest_days;
create policy "own rest days: add" on public.rest_days
  for insert to authenticated
  with check (exists (select 1 from public.profiles p
                      where p.id = rest_days.profile_id and p.account_id = auth.uid()));

drop policy if exists "own rest days: remove" on public.rest_days;
create policy "own rest days: remove" on public.rest_days
  for delete to authenticated
  using (exists (select 1 from public.profiles p
                 where p.id = rest_days.profile_id and p.account_id = auth.uid()));

create or replace function public.enforce_rest_day_rules()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_utc_today date := (now() at time zone 'UTC')::date;
begin
  if new.local_date < v_utc_today - 1 or new.local_date > v_utc_today + 8 then
    raise exception 'rest day date not allowed' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtext(new.profile_id::text));
  if (select count(*) from public.rest_days
       where profile_id = new.profile_id
         and date_trunc('week', local_date) = date_trunc('week', new.local_date)) >= 2 then
    raise exception 'rest day limit reached: at most 2 per week' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists rest_days_rules on public.rest_days;
create trigger rest_days_rules before insert on public.rest_days
  for each row execute function public.enforce_rest_day_rules();


-- ################ migrations/0005_events.sql ################
-- =====================================================================
-- 0005_events: walkathon events (date slots) and their member rosters.
--
--  * A Super Admin creates any number of events; each is a date slot.
--  * Each event has a ROSTER of accounts (household logins), filled by
--    bulk CSV import or one by one. Every profile on a rostered account
--    takes part in that event.
--  * Members can see the events they are on; only Super Admins can see
--    rosters or change anything. All writes go through functions that
--    check the caller, or through the admin Edge Function (service role).
-- Event leaderboards are added with the leaderboard phase.
-- =====================================================================
create table if not exists public.events (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 2 and 80),
  description text check (char_length(description) <= 500),
  starts_on   date not null,
  ends_on     date not null,
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  check (ends_on >= starts_on and ends_on - starts_on <= 365)
);

create table if not exists public.event_accounts (
  event_id   uuid not null references public.events (id) on delete cascade,
  account_id uuid not null references auth.users (id) on delete cascade,
  added_at   timestamptz not null default now(),
  primary key (event_id, account_id)
);
create index if not exists event_accounts_account_idx on public.event_accounts (account_id);

alter table public.events enable row level security;
alter table public.event_accounts enable row level security;
revoke all on public.events, public.event_accounts from anon, authenticated;
grant select on public.events, public.event_accounts to authenticated;

drop policy if exists "see own roster rows" on public.event_accounts;
create policy "see own roster rows" on public.event_accounts
  for select to authenticated
  using (account_id = auth.uid() or public.is_platform_admin());

drop policy if exists "see events you are on" on public.events;
create policy "see events you are on" on public.events
  for select to authenticated
  using (public.is_platform_admin()
         or exists (select 1 from public.event_accounts ea
                    where ea.event_id = events.id and ea.account_id = auth.uid()));

-- ---------- Super Admin functions ----------
create or replace function public.admin_create_event(
  p_name text, p_starts_on date, p_ends_on date, p_description text default null
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  insert into public.events (name, description, starts_on, ends_on, created_by)
  values (btrim(p_name), nullif(btrim(p_description), ''), p_starts_on, p_ends_on, auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_delete_event(p_event_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  delete from public.events where id = p_event_id;
end;
$$;

create or replace function public.admin_list_events()
returns table (id uuid, name text, description text, starts_on date, ends_on date, member_count bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  return query
    select e.id, e.name, e.description, e.starts_on, e.ends_on,
           (select count(*) from public.event_accounts ea where ea.event_id = e.id)
    from public.events e
    order by e.starts_on desc, e.created_at desc;
end;
$$;

create or replace function public.admin_event_roster(p_event_id uuid)
returns table (account_id uuid, email text, added_at timestamptz, profile_count bigint, has_signed_in boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  return query
    select u.id, u.email::text, ea.added_at,
           (select count(*) from public.profiles p where p.account_id = u.id),
           u.last_sign_in_at is not null
    from public.event_accounts ea
    join auth.users u on u.id = ea.account_id
    where ea.event_id = p_event_id
    order by u.email;
end;
$$;

create or replace function public.admin_remove_event_account(p_event_id uuid, p_account_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  delete from public.event_accounts where event_id = p_event_id and account_id = p_account_id;
end;
$$;

revoke all on function public.admin_create_event(text, date, date, text),
                       public.admin_delete_event(uuid),
                       public.admin_list_events(),
                       public.admin_event_roster(uuid),
                       public.admin_remove_event_account(uuid, uuid)
  from public, anon;
grant execute on function public.admin_create_event(text, date, date, text),
                          public.admin_delete_event(uuid),
                          public.admin_list_events(),
                          public.admin_event_roster(uuid),
                          public.admin_remove_event_account(uuid, uuid)
  to authenticated;

-- ---------- service-role helper for the bulk import Edge Function ----------
-- Maps emails to existing account ids. Never callable by app users.
create or replace function public.account_ids_by_emails(p_emails text[])
returns table (email text, account_id uuid)
language sql stable security definer set search_path = ''
as $$
  select lower(u.email)::text, u.id
  from auth.users u
  where lower(u.email) = any (select lower(x) from unnest(p_emails) as x);
$$;
revoke all on function public.account_ids_by_emails(text[]) from public, anon, authenticated;
grant execute on function public.account_ids_by_emails(text[]) to service_role;


-- ################ migrations/0006_device_binding.sql ################
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


-- ################ migrations/0007_event_board.sql ################
-- =====================================================================
-- 0007_event_board: the event dashboard's data, in one call.
--
-- Ranks every profile on the event's roster by steps inside the chosen
-- window. Only roster members (and Super Admins) may call it. It exposes
-- display names and step totals only, which members accepted at first
-- sign-in. No emails, no body details, no per-day history of others.
--
-- p_period: 'event' (whole event so far) | 'week' | 'day'
-- p_local_date: the caller's local date (only +/- 1 day of UTC is honoured).
--
-- NOTE: 0010_scoring replaces this function with an extended version
-- (metrics, men/women boards, percentile). Run 0007 before 0010.
-- =====================================================================
create or replace function public.event_board(
  p_event_id   uuid,
  p_period     text default 'event',
  p_local_date date default null,
  p_limit      int  default 50
) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  e        public.events%rowtype;
  v_utc    date := (now() at time zone 'UTC')::date;
  v_today  date;
  v_from   date;
  v_to     date;
  v_limit  int := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found
     or not (public.is_platform_admin()
             or exists (select 1 from public.event_accounts
                         where event_id = p_event_id and account_id = auth.uid())) then
    raise exception 'event not available' using errcode = 'insufficient_privilege';
  end if;
  if p_period not in ('event', 'week', 'day') then
    raise exception 'invalid period' using errcode = 'invalid_parameter_value';
  end if;

  v_today := least(greatest(coalesce(p_local_date, v_utc), v_utc - 1), v_utc + 1);
  if p_period = 'day' then
    v_from := v_today; v_to := v_today;
  elsif p_period = 'week' then
    v_from := date_trunc('week', v_today)::date; v_to := v_from + 6;
  else
    v_from := e.starts_on; v_to := e.ends_on;
  end if;
  -- never outside the event, never in the future
  v_from := greatest(v_from, e.starts_on);
  v_to   := least(v_to, e.ends_on, v_today);

  with totals as (
    select p.id as profile_id,
           case when btrim(p.display_name) = '' then 'Walker' else p.display_name end as name,
           p.account_id = auth.uid() as mine,
           coalesce(sum(sd.steps), 0)::bigint as steps
      from public.event_accounts ea
      join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
      left join public.step_days sd
             on sd.profile_id = p.id and sd.local_date between v_from and v_to
     where ea.event_id = p_event_id
     group by p.id, p.display_name, p.account_id
  ),
  ranked as (
    select t.*, rank() over (order by t.steps desc) as rnk from totals t
  )
  select jsonb_build_object(
    'event', jsonb_build_object('id', e.id, 'name', e.name,
                                'starts_on', e.starts_on, 'ends_on', e.ends_on),
    'period', p_period,
    'from', v_from, 'to', v_to, 'today', v_today,
    'walkers', (select count(*) from ranked),
    'active_walkers', (select count(*) from ranked where steps > 0),
    'total_steps', (select coalesce(sum(steps), 0) from ranked),
    'rows', coalesce((select jsonb_agg(x order by (x ->> 'rank')::int, x ->> 'name')
                        from (select jsonb_build_object(
                                       'rank', rnk, 'profile_id', profile_id, 'name', name,
                                       'steps', steps, 'mine', mine) as x
                                from ranked order by rnk, name limit v_limit) q), '[]'::jsonb),
    'mine', coalesce((select jsonb_agg(jsonb_build_object(
                                 'rank', rnk, 'profile_id', profile_id, 'name', name,
                                 'steps', steps, 'mine', true) order by rnk, name)
                        from ranked where mine), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.event_board(uuid, text, date, int) from public, anon;
grant execute on function public.event_board(uuid, text, date, int) to authenticated;


-- ################ migrations/0008_friends.sql ################
-- =====================================================================
-- 0008_friends: friends between walker profiles, with privacy controls.
--
--  * Friendship needs acceptance. Nobody sees anyone's steps without it.
--  * An accepted friend sees a profile's name and step totals ONLY while
--    that profile's "share steps with friends" switch is on.
--  * Hide = I stop seeing them in my lists and boards (they are not told).
--  * Block = the friendship ends, and they can no longer find or request me.
--    A blocked person is told nothing ("not found").
--  * People add each other with a personal friend code, or directly when
--    they are on the same event (where names are already visible).
-- Tables have no client access at all; everything goes through functions
-- that verify the calling account owns the acting profile.
-- =====================================================================

-- Sharing switch: accepting a friend is the consent, the switch is the
-- per-profile off button. Nobody had friends before this migration, so
-- turning it on by default exposes nothing until a request is accepted.
alter table public.profiles alter column steps_visibility set default 'friends';
update public.profiles set steps_visibility = 'friends' where steps_visibility = 'private';

alter table public.profiles add column if not exists friend_code text unique;

create table if not exists public.friendships (
  profile_a    uuid not null references public.profiles (id) on delete cascade,
  profile_b    uuid not null references public.profiles (id) on delete cascade,
  status       text not null check (status in ('pending', 'accepted')),
  requested_by uuid not null references public.profiles (id) on delete cascade,
  created_at   timestamptz not null default now(),
  accepted_at  timestamptz,
  primary key (profile_a, profile_b),
  check (profile_a < profile_b)
);
create index if not exists friendships_b_idx on public.friendships (profile_b);

create table if not exists public.friend_hidden (
  owner_profile  uuid not null references public.profiles (id) on delete cascade,
  friend_profile uuid not null references public.profiles (id) on delete cascade,
  primary key (owner_profile, friend_profile)
);

create table if not exists public.profile_blocks (
  blocker_profile uuid not null references public.profiles (id) on delete cascade,
  blocked_profile uuid not null references public.profiles (id) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (blocker_profile, blocked_profile)
);
create index if not exists profile_blocks_blocked_idx on public.profile_blocks (blocked_profile);

alter table public.friendships    enable row level security;
alter table public.friend_hidden  enable row level security;
alter table public.profile_blocks enable row level security;
revoke all on public.friendships, public.friend_hidden, public.profile_blocks from anon, authenticated;

-- ---------- shared helpers ----------
create or replace function public.assert_my_profile(p_profile uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if auth.uid() is null or not exists (
       select 1 from public.profiles
        where id = p_profile and account_id = auth.uid() and deleted_at is null) then
    raise exception 'not your profile' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- The caller's local date, trusted only within a day of UTC.
create or replace function public.clamp_local_date(p_date date)
returns date
language sql stable set search_path = ''
as $$
  select least(greatest(coalesce(p_date, (now() at time zone 'UTC')::date),
                        (now() at time zone 'UTC')::date - 1),
               (now() at time zone 'UTC')::date + 1);
$$;

create or replace function public.profile_label(p_name text)
returns text language sql immutable set search_path = ''
as $$ select case when btrim(coalesce(p_name, '')) = '' then 'Walker' else p_name end $$;

create or replace function public.is_blocked_between(p_one uuid, p_two uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profile_blocks
                  where (blocker_profile = p_one and blocked_profile = p_two)
                     or (blocker_profile = p_two and blocked_profile = p_one));
$$;
revoke all on function public.assert_my_profile(uuid), public.is_blocked_between(uuid, uuid)
  from public, anon, authenticated;

-- ---------- friend code ----------
create or replace function public.my_friend_code(p_me uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare v_code text;
begin
  perform public.assert_my_profile(p_me);
  select friend_code into v_code from public.profiles where id = p_me;
  while v_code is null loop
    begin
      update public.profiles
         set friend_code = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
       where id = p_me
       returning friend_code into v_code;
    exception when unique_violation then
      v_code := null;
    end;
  end loop;
  return v_code;
end;
$$;

-- ---------- request / respond / remove ----------
-- Returns: sent | accepted | pending | already_friends | not_found | limit
create or replace function public.friend_request(
  p_me uuid, p_code text default null, p_profile uuid default null
) returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_target uuid;
  v_a uuid; v_b uuid;
  f public.friendships%rowtype;
begin
  perform public.assert_my_profile(p_me);

  if p_code is not null then
    select id into v_target from public.profiles
     where friend_code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g'))
       and deleted_at is null;
  elsif p_profile is not null then
    -- Direct add is only for people who can already see each other's name:
    -- the two households share an event roster.
    select p.id into v_target
      from public.profiles p
     where p.id = p_profile and p.deleted_at is null
       and exists (select 1
                     from public.event_accounts mine
                     join public.event_accounts theirs on theirs.event_id = mine.event_id
                    where mine.account_id = auth.uid() and theirs.account_id = p.account_id);
  end if;

  -- Blocks are never revealed: a blocked request looks like an unknown code.
  if v_target is null or v_target = p_me or public.is_blocked_between(p_me, v_target) then
    return 'not_found';
  end if;

  v_a := least(p_me, v_target); v_b := greatest(p_me, v_target);
  select * into f from public.friendships where profile_a = v_a and profile_b = v_b;
  if found then
    if f.status = 'accepted' then return 'already_friends'; end if;
    if f.requested_by = p_me then return 'pending'; end if;
    update public.friendships set status = 'accepted', accepted_at = now()
     where profile_a = v_a and profile_b = v_b;
    return 'accepted';
  end if;

  if (select count(*) from public.friendships
       where requested_by = p_me and status = 'pending') >= 30 then
    return 'limit';
  end if;
  insert into public.friendships (profile_a, profile_b, status, requested_by)
  values (v_a, v_b, 'pending', p_me);
  return 'sent';
end;
$$;

create or replace function public.friend_respond(p_me uuid, p_other uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_a uuid := least(p_me, p_other); v_b uuid := greatest(p_me, p_other);
begin
  perform public.assert_my_profile(p_me);
  if p_accept then
    update public.friendships set status = 'accepted', accepted_at = now()
     where profile_a = v_a and profile_b = v_b and status = 'pending' and requested_by = p_other;
  else
    delete from public.friendships
     where profile_a = v_a and profile_b = v_b and status = 'pending' and requested_by = p_other;
  end if;
end;
$$;

-- Ends a friendship, or cancels my own pending request.
create or replace function public.friend_remove(p_me uuid, p_other uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.assert_my_profile(p_me);
  delete from public.friendships
   where profile_a = least(p_me, p_other) and profile_b = greatest(p_me, p_other);
  delete from public.friend_hidden
   where (owner_profile = p_me and friend_profile = p_other)
      or (owner_profile = p_other and friend_profile = p_me);
end;
$$;

create or replace function public.friend_set_hidden(p_me uuid, p_other uuid, p_hidden boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.assert_my_profile(p_me);
  if p_hidden then
    insert into public.friend_hidden (owner_profile, friend_profile)
    select p_me, p_other
     where exists (select 1 from public.friendships
                    where profile_a = least(p_me, p_other) and profile_b = greatest(p_me, p_other))
    on conflict do nothing;
  else
    delete from public.friend_hidden where owner_profile = p_me and friend_profile = p_other;
  end if;
end;
$$;

create or replace function public.friend_block(p_me uuid, p_other uuid, p_blocked boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.assert_my_profile(p_me);
  if p_me = p_other then return; end if;
  if p_blocked then
    insert into public.profile_blocks (blocker_profile, blocked_profile)
    values (p_me, p_other) on conflict do nothing;
    delete from public.friendships
     where profile_a = least(p_me, p_other) and profile_b = greatest(p_me, p_other);
    delete from public.friend_hidden
     where (owner_profile = p_me and friend_profile = p_other)
        or (owner_profile = p_other and friend_profile = p_me);
  else
    delete from public.profile_blocks where blocker_profile = p_me and blocked_profile = p_other;
  end if;
end;
$$;

-- ---------- reads ----------
-- Everything the Friends screen needs, for one of my profiles.
create or replace function public.friends_overview(p_me uuid, p_local_date date default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := public.clamp_local_date(p_local_date);
begin
  perform public.assert_my_profile(p_me);
  return jsonb_build_object(
    'code', public.my_friend_code(p_me),
    'sharing', (select steps_visibility = 'friends' from public.profiles where id = p_me),
    'friends', coalesce((
      select jsonb_agg(jsonb_build_object(
               'profile_id', o.id,
               'name', public.profile_label(o.display_name),
               'hidden', exists (select 1 from public.friend_hidden h
                                  where h.owner_profile = p_me and h.friend_profile = o.id),
               'sharing', o.steps_visibility = 'friends',
               -- steps only while THEY share
               'today_steps', case when o.steps_visibility = 'friends'
                                   then coalesce((select sd.steps from public.step_days sd
                                                   where sd.profile_id = o.id and sd.local_date = v_today), 0)
                              end)
             order by public.profile_label(o.display_name))
        from public.friendships f
        join public.profiles o
          on o.id = case when f.profile_a = p_me then f.profile_b else f.profile_a end
       where (f.profile_a = p_me or f.profile_b = p_me) and f.status = 'accepted'
         and o.deleted_at is null), '[]'::jsonb),
    'incoming', coalesce((
      select jsonb_agg(jsonb_build_object('profile_id', o.id, 'name', public.profile_label(o.display_name))
                       order by f.created_at)
        from public.friendships f
        join public.profiles o on o.id = f.requested_by
       where (f.profile_a = p_me or f.profile_b = p_me)
         and f.status = 'pending' and f.requested_by <> p_me), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(jsonb_build_object('profile_id', o.id, 'name', public.profile_label(o.display_name))
                       order by f.created_at)
        from public.friendships f
        join public.profiles o
          on o.id = case when f.profile_a = p_me then f.profile_b else f.profile_a end
       where (f.profile_a = p_me or f.profile_b = p_me)
         and f.status = 'pending' and f.requested_by = p_me), '[]'::jsonb),
    'blocked', coalesce((
      select jsonb_agg(jsonb_build_object('profile_id', o.id, 'name', public.profile_label(o.display_name))
                       order by b.created_at)
        from public.profile_blocks b
        join public.profiles o on o.id = b.blocked_profile
       where b.blocker_profile = p_me), '[]'::jsonb));
end;
$$;

-- Me plus the friends I have not hidden and who share their steps.
-- p_period: day | week | month
create or replace function public.friend_board(
  p_me uuid, p_period text default 'day', p_local_date date default null
) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_today date := public.clamp_local_date(p_local_date);
  v_from date; v_to date;
  v_rows jsonb;
begin
  perform public.assert_my_profile(p_me);
  if p_period = 'day' then v_from := v_today; v_to := v_today;
  elsif p_period = 'week' then v_from := date_trunc('week', v_today)::date; v_to := v_from + 6;
  elsif p_period = 'month' then
    v_from := date_trunc('month', v_today)::date;
    v_to := (date_trunc('month', v_today) + interval '1 month - 1 day')::date;
  else
    raise exception 'invalid period' using errcode = 'invalid_parameter_value';
  end if;
  v_to := least(v_to, v_today);

  with people as (
    select p_me as id
    union
    select o.id
      from public.friendships f
      join public.profiles o
        on o.id = case when f.profile_a = p_me then f.profile_b else f.profile_a end
     where (f.profile_a = p_me or f.profile_b = p_me) and f.status = 'accepted'
       and o.deleted_at is null and o.steps_visibility = 'friends'
       and not exists (select 1 from public.friend_hidden h
                        where h.owner_profile = p_me and h.friend_profile = o.id)
  ),
  totals as (
    select pr.id, public.profile_label(pr.display_name) as name,
           coalesce(sum(sd.steps), 0)::bigint as steps
      from people pe
      join public.profiles pr on pr.id = pe.id
      left join public.step_days sd
             on sd.profile_id = pr.id and sd.local_date between v_from and v_to
     group by pr.id, pr.display_name
  ),
  ranked as (select t.*, rank() over (order by t.steps desc) as rnk from totals t)
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank', rnk, 'profile_id', id, 'name', name, 'steps', steps, 'mine', id = p_me)
           order by rnk, name), '[]'::jsonb)
    into v_rows from ranked;

  return jsonb_build_object('period', p_period, 'from', v_from, 'to', v_to, 'rows', v_rows);
end;
$$;

revoke all on function
  public.my_friend_code(uuid), public.friend_request(uuid, text, uuid),
  public.friend_respond(uuid, uuid, boolean), public.friend_remove(uuid, uuid),
  public.friend_set_hidden(uuid, uuid, boolean), public.friend_block(uuid, uuid, boolean),
  public.friends_overview(uuid, date), public.friend_board(uuid, text, date)
  from public, anon;
grant execute on function
  public.my_friend_code(uuid), public.friend_request(uuid, text, uuid),
  public.friend_respond(uuid, uuid, boolean), public.friend_remove(uuid, uuid),
  public.friend_set_hidden(uuid, uuid, boolean), public.friend_block(uuid, uuid, boolean),
  public.friends_overview(uuid, date), public.friend_board(uuid, text, date)
  to authenticated;
grant execute on function public.clamp_local_date(date), public.profile_label(text) to authenticated;


-- ################ migrations/0009_groups.sql ################
-- =====================================================================
-- 0009_groups: private groups, invite codes, fixed-date challenges,
-- Mystery Mode and admin report export.
--
--  * Walker PROFILES join groups (each household member separately).
--  * Roles: owner, admin, member. Every permission is checked here.
--  * Joining needs an invite code created by an admin. Codes are stored
--    hashed, can expire, can be capped and revoked; wrong guesses are
--    rate-limited per account.
--  * Joining a group shares name and step totals with its members.
--  * Boards update automatically; nothing has to be "started".
--  * Mystery Mode: today's counts are hidden from everyone (ranks only)
--    and revealed the next day. To keep today un-derivable, the longer
--    periods stop at yesterday while it is on.
--  * A challenge is a date range (1 to 366 days). Its board stays readable
--    after it ends until an admin changes or clears it.
--  * Up to 15,000 members per group.
-- =====================================================================
create table if not exists public.groups (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(btrim(name)) between 2 and 60),
  chat_enabled    boolean not null default true,
  taunts_enabled  boolean not null default true,
  mystery_mode    boolean not null default false,
  -- The group's own clock (minutes from UTC), set by its admin. Mystery Mode
  -- uses it to decide what "today" is, so a member cannot unlock today's
  -- counts by claiming a different date.
  tz_offset_min   int not null default 0 check (tz_offset_min between -840 and 840),
  challenge_start date,
  challenge_end   date,
  created_at      timestamptz not null default now(),
  check ((challenge_start is null) = (challenge_end is null)),
  check (challenge_end >= challenge_start and challenge_end - challenge_start <= 365)
);

create table if not exists public.group_members (
  group_id   uuid not null references public.groups (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  role       text not null default 'member' check (role in ('owner', 'admin', 'member')),
  joined_at  timestamptz not null default now(),
  primary key (group_id, profile_id)
);
create index if not exists group_members_profile_idx on public.group_members (profile_id);
create unique index if not exists group_one_owner on public.group_members (group_id) where role = 'owner';

create table if not exists public.group_invites (
  id         uuid primary key default gen_random_uuid(),
  group_id   uuid not null references public.groups (id) on delete cascade,
  code_hash  text not null unique,
  created_by uuid references public.profiles (id) on delete set null,
  expires_at timestamptz not null,
  max_uses   int check (max_uses > 0),
  uses       int not null default 0,
  revoked_at timestamptz
);

create table if not exists public.group_join_attempts (
  account_id uuid not null references auth.users (id) on delete cascade,
  at         timestamptz not null default now()
);
create index if not exists group_join_attempts_idx on public.group_join_attempts (account_id, at);

alter table public.groups              enable row level security;
alter table public.group_members       enable row level security;
alter table public.group_invites       enable row level security;
alter table public.group_join_attempts enable row level security;
revoke all on public.groups, public.group_members, public.group_invites, public.group_join_attempts
  from anon, authenticated;

-- ---------- helpers ----------
create or replace function public.group_role(p_group uuid, p_profile uuid)
returns text
language sql stable security definer set search_path = ''
as $$ select role from public.group_members where group_id = p_group and profile_id = p_profile $$;

-- Verifies the caller owns p_me AND p_me is in the group; returns the role.
create or replace function public.require_group_role(p_me uuid, p_group uuid, p_admin boolean)
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare v_role text;
begin
  perform public.assert_my_profile(p_me);
  v_role := public.group_role(p_group, p_me);
  if v_role is null or (p_admin and v_role not in ('owner', 'admin')) then
    raise exception 'not allowed in this group' using errcode = 'insufficient_privilege';
  end if;
  return v_role;
end;
$$;

create or replace function public.hash_invite_code(p_code text)
returns text language sql immutable set search_path = ''
as $$ select encode(sha256(convert_to(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'UTF8')), 'hex') $$;

revoke all on function public.group_role(uuid, uuid), public.require_group_role(uuid, uuid, boolean),
                       public.hash_invite_code(text)
  from public, anon, authenticated;

-- ---------- create / settings / delete ----------
create or replace function public.group_create(p_me uuid, p_name text, p_tz_offset_min int default 0)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  perform public.assert_my_profile(p_me);
  if (select count(*) from public.group_members where profile_id = p_me and role = 'owner') >= 20 then
    raise exception 'group limit reached' using errcode = 'check_violation';
  end if;
  insert into public.groups (name, tz_offset_min)
  values (btrim(p_name), coalesce(p_tz_offset_min, 0)) returning id into v_id;
  insert into public.group_members (group_id, profile_id, role) values (v_id, p_me, 'owner');
  return v_id;
end;
$$;

-- Null arguments leave a setting unchanged.
create or replace function public.group_update(
  p_me uuid, p_group uuid,
  p_name text default null, p_chat boolean default null,
  p_taunts boolean default null, p_mystery boolean default null,
  p_tz_offset_min int default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_group_role(p_me, p_group, true);
  update public.groups
     set name           = coalesce(nullif(btrim(p_name), ''), name),
         chat_enabled   = coalesce(p_chat, chat_enabled),
         taunts_enabled = coalesce(p_taunts, taunts_enabled),
         mystery_mode   = coalesce(p_mystery, mystery_mode),
         tz_offset_min  = coalesce(p_tz_offset_min, tz_offset_min)
   where id = p_group;
end;
$$;

-- Pass both dates to create/change the challenge, both null to clear it.
create or replace function public.group_set_challenge(p_me uuid, p_group uuid, p_start date, p_end date)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.require_group_role(p_me, p_group, true);
  update public.groups set challenge_start = p_start, challenge_end = p_end where id = p_group;
end;
$$;

create or replace function public.group_delete(p_me uuid, p_group uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.require_group_role(p_me, p_group, true) <> 'owner' then
    raise exception 'only the owner can delete the group' using errcode = 'insufficient_privilege';
  end if;
  delete from public.groups where id = p_group;
end;
$$;

-- ---------- invites ----------
-- Returns the code ONCE (only its hash is stored).
create or replace function public.group_invite_create(
  p_me uuid, p_group uuid, p_days int default 14, p_max_uses int default null
) returns text
language plpgsql security definer set search_path = ''
as $$
declare v_code text;
begin
  perform public.require_group_role(p_me, p_group, true);
  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  insert into public.group_invites (group_id, code_hash, created_by, expires_at, max_uses)
  values (p_group, public.hash_invite_code(v_code), p_me,
          now() + make_interval(days => least(greatest(coalesce(p_days, 14), 1), 90)), p_max_uses);
  return substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4);
end;
$$;

create or replace function public.group_invites_revoke(p_me uuid, p_group uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  perform public.require_group_role(p_me, p_group, true);
  update public.group_invites set revoked_at = now()
   where group_id = p_group and revoked_at is null;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Returns {status, group_id?}: joined | already_member | invalid | full | rate_limited
-- (statuses, not exceptions, so failed attempts are recorded).
create or replace function public.group_join(p_me uuid, p_code text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  i public.group_invites%rowtype;
begin
  perform public.assert_my_profile(p_me);
  if (select count(*) from public.group_join_attempts
       where account_id = auth.uid() and at > now() - interval '15 minutes') >= 10 then
    return jsonb_build_object('status', 'rate_limited');
  end if;

  select * into i from public.group_invites
   where code_hash = public.hash_invite_code(p_code)
     and revoked_at is null and expires_at > now()
     and (max_uses is null or uses < max_uses)
   for update;
  if not found then
    insert into public.group_join_attempts (account_id) values (auth.uid());
    return jsonb_build_object('status', 'invalid');
  end if;

  if public.group_role(i.group_id, p_me) is not null then
    return jsonb_build_object('status', 'already_member', 'group_id', i.group_id);
  end if;
  if (select count(*) from public.group_members where group_id = i.group_id) >= 15000 then
    return jsonb_build_object('status', 'full');
  end if;

  insert into public.group_members (group_id, profile_id, role) values (i.group_id, p_me, 'member');
  update public.group_invites set uses = uses + 1 where id = i.id;
  return jsonb_build_object('status', 'joined', 'group_id', i.group_id);
end;
$$;

-- ---------- membership ----------
create or replace function public.group_leave(p_me uuid, p_group uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_role text := public.require_group_role(p_me, p_group, false);
begin
  if v_role = 'owner' then
    if (select count(*) from public.group_members where group_id = p_group) > 1 then
      raise exception 'make someone else the owner first, or delete the group'
        using errcode = 'check_violation';
    end if;
    delete from public.groups where id = p_group; -- last person out
    return;
  end if;
  delete from public.group_members where group_id = p_group and profile_id = p_me;
end;
$$;

create or replace function public.group_remove_member(p_me uuid, p_group uuid, p_target uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_role   text := public.require_group_role(p_me, p_group, true);
  v_target text := public.group_role(p_group, p_target);
begin
  if v_target is null or p_target = p_me then return; end if;
  if v_target = 'owner' or (v_target = 'admin' and v_role <> 'owner') then
    raise exception 'you cannot remove this member' using errcode = 'insufficient_privilege';
  end if;
  delete from public.group_members where group_id = p_group and profile_id = p_target;
end;
$$;

-- Owner only. p_role: admin | member | owner (owner = hand the group over).
create or replace function public.group_set_role(p_me uuid, p_group uuid, p_target uuid, p_role text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if public.require_group_role(p_me, p_group, true) <> 'owner' then
    raise exception 'only the owner can change roles' using errcode = 'insufficient_privilege';
  end if;
  if p_role not in ('owner', 'admin', 'member') or p_target = p_me
     or public.group_role(p_group, p_target) is null then
    raise exception 'invalid role change' using errcode = 'invalid_parameter_value';
  end if;
  if p_role = 'owner' then
    update public.group_members set role = 'admin' where group_id = p_group and profile_id = p_me;
  end if;
  update public.group_members set role = p_role where group_id = p_group and profile_id = p_target;
end;
$$;

-- ---------- reads ----------
create or replace function public.my_groups(p_me uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.assert_my_profile(p_me);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', g.id, 'name', g.name, 'role', m.role,
             'member_count', (select count(*) from public.group_members x where x.group_id = g.id),
             'mystery_mode', g.mystery_mode, 'chat_enabled', g.chat_enabled,
             'taunts_enabled', g.taunts_enabled, 'tz_offset_min', g.tz_offset_min,
             'challenge_start', g.challenge_start, 'challenge_end', g.challenge_end)
           order by g.name)
      from public.group_members m join public.groups g on g.id = m.group_id
     where m.profile_id = p_me), '[]'::jsonb);
end;
$$;

create or replace function public.group_members_list(p_me uuid, p_group uuid, p_limit int default 500)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.require_group_role(p_me, p_group, false);
  return coalesce((
    select jsonb_agg(x order by x ->> 'sort', x ->> 'name')
      from (select jsonb_build_object(
                     'profile_id', p.id, 'name', public.profile_label(p.display_name),
                     'role', m.role, 'mine', p.account_id = auth.uid(),
                     'sort', case m.role when 'owner' then '0' when 'admin' then '1' else '2' end) as x
              from public.group_members m join public.profiles p on p.id = m.profile_id
             where m.group_id = p_group
             order by case m.role when 'owner' then 0 when 'admin' then 1 else 2 end, p.display_name
             limit least(greatest(coalesce(p_limit, 500), 1), 1000)) q), '[]'::jsonb);
end;
$$;

-- p_period: day | week | month | challenge
create or replace function public.group_board(
  p_me uuid, p_group uuid, p_period text default 'day',
  p_local_date date default null, p_limit int default 100
) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  g        public.groups%rowtype;
  v_role   text := public.require_group_role(p_me, p_group, false);
  v_today  date := public.clamp_local_date(p_local_date);
  v_gtoday date;               -- today on the GROUP's clock
  v_from   date; v_to date;
  v_hide   boolean := false;   -- hide the counts (Mystery Mode, today)
  v_excl   boolean := false;   -- longer period stops at yesterday
  v_limit  int := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_result jsonb;
begin
  select * into g from public.groups where id = p_group;
  if p_period = 'day' then v_from := v_today; v_to := v_today;
  elsif p_period = 'week' then v_from := date_trunc('week', v_today)::date; v_to := v_from + 6;
  elsif p_period = 'month' then
    v_from := date_trunc('month', v_today)::date;
    v_to := (date_trunc('month', v_today) + interval '1 month - 1 day')::date;
  elsif p_period = 'challenge' and g.challenge_start is not null then
    v_from := g.challenge_start; v_to := g.challenge_end;
  else
    raise exception 'invalid period' using errcode = 'invalid_parameter_value';
  end if;
  v_to := least(v_to, v_today);

  if g.mystery_mode then
    -- Decided on the group's clock, never the caller's claimed date.
    v_gtoday := ((now() at time zone 'UTC') + make_interval(mins => g.tz_offset_min))::date;
    if p_period = 'day' then
      v_hide := v_today >= v_gtoday;
    elsif v_to >= v_gtoday then
      v_to := v_gtoday - 1; v_excl := true;
    end if;
  end if;

  with totals as (
    select p.id as profile_id, public.profile_label(p.display_name) as name,
           p.account_id = auth.uid() as mine,
           coalesce(sum(sd.steps), 0)::bigint as steps
      from public.group_members m
      join public.profiles p on p.id = m.profile_id and p.deleted_at is null
      left join public.step_days sd
             on sd.profile_id = p.id and sd.local_date between v_from and v_to
     where m.group_id = p_group
     group by p.id, p.display_name, p.account_id
  ),
  ranked as (select t.*, rank() over (order by t.steps desc) as rnk from totals t),
  shaped as (
    select rnk, name, mine,
           jsonb_build_object('rank', rnk, 'profile_id', profile_id, 'name', name, 'mine', mine,
             -- Mystery Mode: counts are withheld for everyone but yourself
             'steps', case when v_hide and not mine then null else steps end) as x
      from ranked
  )
  select jsonb_build_object(
    'group', jsonb_build_object(
      'id', g.id, 'name', g.name, 'my_role', v_role,
      'mystery_mode', g.mystery_mode, 'chat_enabled', g.chat_enabled,
      'taunts_enabled', g.taunts_enabled,
      'challenge_start', g.challenge_start, 'challenge_end', g.challenge_end,
      'member_count', (select count(*) from ranked)),
    'period', p_period, 'from', v_from, 'to', v_to, 'today', v_today,
    'steps_hidden', v_hide, 'excludes_today', v_excl,
    'rows', coalesce((select jsonb_agg(q.x order by q.rnk, q.name)
                        from (select * from shaped order by rnk, name limit v_limit) q), '[]'::jsonb),
    'mine', coalesce((select jsonb_agg(s.x order by s.rnk, s.name) from shaped s where s.mine), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

-- Admin report: one row per member for any date range (max 366 days).
create or replace function public.group_export(p_me uuid, p_group uuid, p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  g       public.groups%rowtype;
  v_today date := (now() at time zone 'UTC')::date;
  v_to    date;
  v_result jsonb;
begin
  perform public.require_group_role(p_me, p_group, true);
  select * into g from public.groups where id = p_group;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 365 then
    raise exception 'invalid date range (1 to 366 days)' using errcode = 'invalid_parameter_value';
  end if;
  -- never the future; with Mystery Mode on, never today either
  v_to := least(p_to, case when g.mystery_mode
    then ((now() at time zone 'UTC') + make_interval(mins => g.tz_offset_min))::date - 1
    else v_today + 1 end);

  select jsonb_build_object(
    'group', g.name, 'from', p_from, 'to', v_to, 'generated_at', now(),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
              'name', t.name, 'role', t.role, 'total_steps', t.total,
              'active_days', t.active_days, 'best_day', t.best)
              order by t.total desc, t.name), '[]'::jsonb))
    into v_result
    from (select public.profile_label(p.display_name) as name, m.role,
                 coalesce(sum(sd.steps), 0)::bigint as total,
                 count(sd.local_date) filter (where sd.steps > 0) as active_days,
                 coalesce(max(sd.steps), 0) as best
            from public.group_members m
            join public.profiles p on p.id = m.profile_id
            left join public.step_days sd
                   on sd.profile_id = p.id and sd.local_date between p_from and v_to
           where m.group_id = p_group
           group by p.id, p.display_name, m.role) t;

  insert into public.admin_audit_log (actor_id, action, details)
  values (auth.uid(), 'group.export', jsonb_build_object('group_id', p_group, 'from', p_from, 'to', v_to));
  return v_result;
end;
$$;

revoke all on function
  public.group_create(uuid, text, int), public.group_update(uuid, uuid, text, boolean, boolean, boolean, int),
  public.group_set_challenge(uuid, uuid, date, date), public.group_delete(uuid, uuid),
  public.group_invite_create(uuid, uuid, int, int), public.group_invites_revoke(uuid, uuid),
  public.group_join(uuid, text), public.group_leave(uuid, uuid),
  public.group_remove_member(uuid, uuid, uuid), public.group_set_role(uuid, uuid, uuid, text),
  public.my_groups(uuid), public.group_members_list(uuid, uuid, int),
  public.group_board(uuid, uuid, text, date, int), public.group_export(uuid, uuid, date, date)
  from public, anon;
grant execute on function
  public.group_create(uuid, text, int), public.group_update(uuid, uuid, text, boolean, boolean, boolean, int),
  public.group_set_challenge(uuid, uuid, date, date), public.group_delete(uuid, uuid),
  public.group_invite_create(uuid, uuid, int, int), public.group_invites_revoke(uuid, uuid),
  public.group_join(uuid, text), public.group_leave(uuid, uuid),
  public.group_remove_member(uuid, uuid, uuid), public.group_set_role(uuid, uuid, uuid, text),
  public.my_groups(uuid), public.group_members_list(uuid, uuid, int),
  public.group_board(uuid, uuid, text, date, int), public.group_export(uuid, uuid, date, date)
  to authenticated;


-- ################ migrations/0010_scoring.sql ################
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


-- ################ migrations/0002_retire_v1.sql ################
-- =====================================================================
-- 0002_retire_v1: remove the v1 tables and their "everyone can read
-- everything" policies (audit finding S1).
--
-- DESTRUCTIVE: drops all v1 profile and step data permanently.
-- Apply only as part of the confirmed launch reset (after
-- ops.reset_launch_data), never on its own.
-- =====================================================================
drop table if exists public.daily_steps;
drop table if exists public.users;


-- ################ ops/seed_super_admin.sql ################
-- =====================================================================
-- Seed a default Super Admin (idempotent, safe to re-run).
--
--   select ops.seed_super_admin('owner@example.com');
--
-- Effects:
--   1. Adds the email to public.platform_admin_emails (seed data that
--      survives launch resets).
--   2. If an account with that VERIFIED email already exists, promotes it
--      immediately. Otherwise the promotion happens automatically the
--      moment that email's account is created/confirmed.
--
-- The email is passed at run time so it is never committed to the repo.
-- Not callable through the API (schema ops is not exposed; EXECUTE revoked).
--
-- BOOTSTRAP NOTE: public sign-up is disabled, so the first Super Admin
-- account is created in the dashboard (Authentication -> Users -> Add user,
-- tick "Auto Confirm User", set a password), or by an admin Edge Function.
-- =====================================================================
create schema if not exists ops;
revoke all on schema ops from public, anon, authenticated;

create or replace function ops.seed_super_admin(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email    text := lower(btrim(p_email));
  v_promoted int  := 0;
begin
  if session_user = 'authenticator' then
    raise exception 'not available through the API';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email: %', p_email;
  end if;

  insert into public.platform_admin_emails (email) values (v_email)
  on conflict do nothing;

  insert into public.platform_admins (user_id)
  select id from auth.users
   where lower(email) = v_email and email_confirmed_at is not null
  on conflict do nothing;
  get diagnostics v_promoted = row_count;

  return jsonb_build_object('email_seeded', true, 'promoted_now', v_promoted > 0);
end;
$$;
revoke all on function ops.seed_super_admin(text) from public, anon, authenticated;


-- ################ migrations/0011_profile_transfer.sql ################
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


-- ################ migrations/0012_count_integrity_reset.sql ################
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


-- ################ migrations/0013_device_login.sql ################
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


-- ################ migrations/0014_organizer_one_profile.sql ################
-- =====================================================================
-- 0014_organizer_one_profile: an organizer login has exactly ONE profile.
--
-- Organizer rights belong to a login. A login holding a whole family of
-- walker profiles would give every one of them organizer reach, so an
-- organizer (event organizer or the organizer staff role) must be a login
-- with a single profile, and cannot add more profiles afterwards.
-- Super Admins are not restricted. Existing organizers are left as they are.
-- =====================================================================

create or replace function public.profile_count(p_account uuid)
returns int
language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.profiles where account_id = p_account and deleted_at is null; $$;
revoke all on function public.profile_count(uuid) from public, anon, authenticated;

-- returns 'ok' | 'not_found' | 'multiple_profiles'
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
  if public.profile_count(v_uid) > 1 then return 'multiple_profiles'; end if;
  insert into public.event_organizers (event_id, user_id, granted_by)
  values (p_event, v_uid, auth.uid())
  on conflict do nothing;
  insert into public.admin_audit_log (actor_id, action, target_id, details)
  values (auth.uid(), 'organizer.add', v_uid, jsonb_build_object('event_id', p_event));
  return 'ok';
end;
$$;

-- returns 'ok' | 'not_found' | 'multiple_profiles'
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
  if p_role = 'organizer' and public.profile_count(v_uid) > 1 then
    return 'multiple_profiles';
  end if;
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

-- An organizer login cannot grow a second profile.
create or replace function public.block_organizer_extra_profile()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (exists (select 1 from public.event_organizers where user_id = new.account_id)
      or exists (select 1 from public.platform_staff
                  where user_id = new.account_id and role = 'organizer'))
     and not exists (select 1 from public.platform_admins where user_id = new.account_id)
     and public.profile_count(new.account_id) >= 1 then
    raise exception 'organizer logins can have only one profile'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_organizer_single on public.profiles;
create trigger profiles_organizer_single before insert on public.profiles
  for each row execute function public.block_organizer_extra_profile();


-- ################ migrations/0015_super_admin_any_phone.sql ################
-- =====================================================================
-- 0015_super_admin_any_phone: a Super Admin signs in from any phone with no
-- approval (replaces ensure_login_device from 0013). Their phones are
-- recorded as auto-approved, so they never appear in the approvals list.
-- =====================================================================
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
     set last_seen = now(), label = coalesce(left(nullif(btrim(p_label), ''), 60), label),
         status = case when public.is_platform_admin() then 'approved' else status end
   where account_id = auth.uid() and device_id = p_device_id
   returning status into v_status;
  if found then return v_status; end if;

  -- A Super Admin can sign in from any phone: no approval needed.
  if public.is_platform_admin() then
    insert into public.account_devices (account_id, device_id, label, status, auto_reason)
    values (auth.uid(), p_device_id, left(nullif(btrim(p_label), ''), 60), 'approved', 'super_admin')
    on conflict (account_id, device_id) do update set status = 'approved';
    return 'approved';
  end if;

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


-- ################ migrations/0016_reset_own_day.sql ################
-- =====================================================================
-- 0016_reset_own_day: "set to zero" must reach every participant's
-- latest day (replaces admin_reset_counts from 0012).
-- A participant's steps are filed under THEIR local date, which can be a day
-- ahead of the admin's. The reset point is now each profile's own latest
-- recorded day, so nothing recorded so far keeps counting.
-- =====================================================================
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

  -- Each profile is reset at ITS OWN latest recorded day (never before the
  -- caller's today). Participants live in other time zones, so their "today"
  -- can already be tomorrow here; resetting only at the caller's date would
  -- leave that day counting.
  insert into public.event_resets as r (event_id, profile_id, reset_date, baseline_steps, reset_by, note)
  select p_event, p.id, d.reset_date,
         coalesce((select sd.steps from public.step_days sd
                    where sd.profile_id = p.id and sd.local_date = d.reset_date), 0),
         auth.uid(), btrim(p_note)
    from public.event_accounts ea
    join public.profiles p on p.account_id = ea.account_id and p.deleted_at is null
    cross join lateral (
      select greatest(v_today, coalesce((select max(sd2.local_date) from public.step_days sd2
                                          where sd2.profile_id = p.id
                                            and sd2.local_date <= v_today + 2), v_today)) as reset_date) d
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


-- ################ migrations/0017_reset_by_time.sql ################
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


-- ################ migrations/0018_fresh_start.sql ################
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
