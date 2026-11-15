// Super Admin member management. The caller must be a Super Admin, which is
// verified in the database (public.is_platform_admin) with the CALLER's JWT
// before the service-role client is used for anything.
//
// POST { action: "list" }
// POST { action: "create", email, display_name }   -> { temp_password }
// POST { action: "reset_password", account_id }    -> { temp_password }
// POST { action: "disable" | "enable" | "delete", account_id }
// POST { action: "bulk_import", event_id, rows: [{ email, display_name }] }  (max 50 rows)
//      -> { results: [{ email, status, temp_password? }] }
//      status: created | existing | invalid | error
import { callerClient, callerId, corsHeaders, json, serviceClient, tempPassword } from "../_shared/auth.ts";

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const caller = callerClient(req);
  const actorId = await callerId(caller);
  if (!actorId) return json({ error: "unauthorized" }, 401);

  const { data: isAdmin, error: adminErr } = await caller.rpc("is_platform_admin");
  if (adminErr || isAdmin !== true) return json({ error: "forbidden" }, 403);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  const admin = serviceClient();
  const audit = (action: string, target: string | null, details: Record<string, unknown> = {}) =>
    admin.from("admin_audit_log").insert({ actor_id: actorId, action, target_id: target, details });

  switch (body.action) {
    case "list": {
      const { data, error } = await caller.rpc("admin_list_members");
      if (error) return json({ error: "could not list members" }, 500);
      return json({ members: data });
    }

    case "create": {
      const email = String(body.email ?? "").trim().toLowerCase();
      const name = String(body.display_name ?? "").trim().slice(0, 40);
      if (!EMAIL_RE.test(email)) return json({ error: "invalid email" }, 400);
      if (!name) return json({ error: "display_name required" }, 400);
      const password = tempPassword();
      const { data, error } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { name, must_change_password: true },
      });
      if (error || !data.user) {
        const exists = /already|registered|exists/i.test(error?.message ?? "");
        return json({ error: exists ? "email already registered" : "could not create member" }, exists ? 409 : 500);
      }
      await audit("member.create", data.user.id);
      // The temporary password is returned ONCE and never stored.
      return json({ account_id: data.user.id, temp_password: password }, 201);
    }

    case "reset_password": {
      const id = String(body.account_id ?? "");
      if (!UUID_RE.test(id)) return json({ error: "invalid account_id" }, 400);
      const password = tempPassword();
      const { error } = await admin.auth.admin.updateUserById(id, {
        password,
        user_metadata: { must_change_password: true },
      });
      if (error) return json({ error: "could not reset password" }, 500);
      await audit("member.reset_password", id);
      return json({ temp_password: password });
    }

    case "disable":
    case "enable":
    case "delete": {
      const id = String(body.account_id ?? "");
      if (!UUID_RE.test(id)) return json({ error: "invalid account_id" }, 400);
      if (id === actorId) return json({ error: "you cannot do this to your own account" }, 400);
      const { error } = body.action === "delete"
        ? await admin.auth.admin.deleteUser(id)
        : await admin.auth.admin.updateUserById(id, {
          ban_duration: body.action === "disable" ? "876000h" : "none",
        });
      if (error) return json({ error: `could not ${body.action} member` }, 500);
      await audit(`member.${body.action}`, id);
      return json({ ok: true });
    }

    case "bulk_import": {
      const eventId = String(body.event_id ?? "");
      if (!UUID_RE.test(eventId)) return json({ error: "invalid event_id" }, 400);
      const rows = Array.isArray(body.rows) ? body.rows as Record<string, unknown>[] : null;
      if (!rows || rows.length === 0 || rows.length > 50) {
        return json({ error: "rows must contain 1 to 50 entries" }, 400);
      }
      const { data: ev } = await admin.from("events").select("id").eq("id", eventId).maybeSingle();
      if (!ev) return json({ error: "event not found" }, 404);

      // Normalise, validate and de-duplicate.
      type Row = { email: string; name: string };
      const seen = new Set<string>();
      const valid: Row[] = [];
      const results: { email: string; status: string; temp_password?: string }[] = [];
      for (const r of rows) {
        const email = String(r?.email ?? "").trim().toLowerCase();
        const name = String(r?.display_name ?? "").trim().slice(0, 40) || email.split("@")[0].slice(0, 40);
        if (!EMAIL_RE.test(email) || email.length > 254) {
          results.push({ email, status: "invalid" });
        } else if (!seen.has(email)) {
          seen.add(email);
          valid.push({ email, name });
        }
      }

      // Which emails already have an account?
      const { data: found, error: lookupErr } = await admin.rpc("account_ids_by_emails", {
        p_emails: valid.map((v) => v.email),
      });
      if (lookupErr) return json({ error: "could not look up accounts" }, 500);
      const ids = new Map<string, string>();
      for (const f of (found ?? []) as { email: string; account_id: string }[]) ids.set(f.email, f.account_id);

      const roster: { event_id: string; account_id: string }[] = [];
      let created = 0;
      for (const v of valid) {
        const existing = ids.get(v.email);
        if (existing) {
          roster.push({ event_id: eventId, account_id: existing });
          results.push({ email: v.email, status: "existing" });
          continue;
        }
        const password = tempPassword();
        const { data, error } = await admin.auth.admin.createUser({
          email: v.email,
          password,
          email_confirm: true,
          user_metadata: { name: v.name, must_change_password: true },
        });
        if (error || !data.user) {
          results.push({ email: v.email, status: "error" });
          continue;
        }
        created++;
        roster.push({ event_id: eventId, account_id: data.user.id });
        // Returned ONCE to the admin; never stored or logged.
        results.push({ email: v.email, status: "created", temp_password: password });
      }

      if (roster.length > 0) {
        const { error: rosterErr } = await admin.from("event_accounts")
          .upsert(roster, { onConflict: "event_id,account_id", ignoreDuplicates: true });
        if (rosterErr) return json({ error: "accounts were created but could not be added to the event", results }, 500);
      }
      // Counts only: no emails or passwords in the audit log.
      await audit("event.bulk_import", null, { event_id: eventId, rows: rows.length, created, added: roster.length });
      return json({ results });
    }

    default:
      return json({ error: "unknown action" }, 400);
  }
});
