// Self-service account deletion. Requires the caller's JWT plus a fresh
// password confirmation. Deletes the auth user; profiles and (later) all
// profile-owned rows cascade. Storage files are removed here too once
// buckets exist (Phase 6).
import { callerClient, corsHeaders, json, serviceClient } from "../_shared/auth.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const caller = callerClient(req);
  const { data } = await caller.auth.getUser();
  const user = data.user;
  if (!user || !user.email) return json({ error: "unauthorized" }, 401);

  let body: { password?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }
  if (!body.password) return json({ error: "password required" }, 400);

  // Re-verify the password with a throwaway client so this call cannot be
  // made with a stolen session token alone.
  const verifier = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
  });
  const { error: pwErr } = await verifier.auth.signInWithPassword({
    email: user.email,
    password: body.password,
  });
  if (pwErr) return json({ error: "incorrect password" }, 403);

  const admin = serviceClient();
  // Deleting a Super Admin would orphan the platform; require another admin first.
  const { count } = await admin.from("platform_admins").select("user_id", { count: "exact", head: true });
  const { data: me } = await admin.from("platform_admins").select("user_id").eq("user_id", user.id).maybeSingle();
  if (me && (count ?? 0) <= 1) {
    return json({ error: "you are the only Super Admin; appoint another first" }, 409);
  }

  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) return json({ error: "could not delete account" }, 500);
  await admin.from("admin_audit_log").insert({ actor_id: user.id, action: "account.self_delete", target_id: user.id });
  return json({ ok: true });
});
