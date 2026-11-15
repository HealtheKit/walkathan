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
