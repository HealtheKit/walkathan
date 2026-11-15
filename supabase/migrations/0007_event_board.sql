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
