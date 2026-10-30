import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { action, ...data } = await req.json();
    const url = Deno.env.get("SUPABASE_URL")!;
    const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? secretKeys.default ?? Object.values(secretKeys)[0];
    if (!serviceKey) throw new Error("Supabase server secret key is not configured.");
    const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
    const { data: result, error } = await admin.rpc("game_action", { p_action: action, p_data: data });
    if (error) throw error;
    if (result?.error) return new Response(JSON.stringify({ error: result.error }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });

    const roomCode = result?.code || data?.code;
    if (roomCode && action !== "get_state") {
      const channel = admin.channel(`room:${roomCode}`, { config: { private: false } });
      await channel.httpSend({ type: "broadcast", event: "state_changed", payload: { action, at: new Date().toISOString() } });
    }
    return new Response(JSON.stringify(result), { headers: { ...cors, "Content-Type": "application/json" } });
  } catch (err) {
    return new Response(JSON.stringify({ error: err?.message || "Unexpected server error" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
