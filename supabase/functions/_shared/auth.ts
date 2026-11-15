import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/** Client acting as the CALLER (their JWT), so RLS and auth.uid() apply. */
export function callerClient(req: Request): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
}

/** Service-role client. Never expose this to callers; only use after authorizing. */
export function serviceClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
}

/** Returns the caller's user id, or null when the JWT is missing/invalid. */
export async function callerId(client: SupabaseClient): Promise<string | null> {
  const { data, error } = await client.auth.getUser();
  return error || !data.user ? null : data.user.id;
}

/** Random temporary password: 14 chars, letters+digits, no look-alikes. */
export function tempPassword(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(14));
  return Array.from(bytes, (b) => chars[b % chars.length]).join("");
}
