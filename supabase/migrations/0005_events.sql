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
