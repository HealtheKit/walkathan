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
