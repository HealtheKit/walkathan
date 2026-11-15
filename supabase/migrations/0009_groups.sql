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
