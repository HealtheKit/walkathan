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
