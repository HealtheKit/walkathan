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
