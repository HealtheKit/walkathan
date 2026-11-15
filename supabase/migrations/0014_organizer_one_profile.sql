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
