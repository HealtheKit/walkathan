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
