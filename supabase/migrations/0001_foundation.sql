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
