import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }

  try {
    const { action, ...data } = await req.json();

    const url = Deno.env.get("SUPABASE_URL");
    const secretKeys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    const serviceKey =
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
      secretKeys.default ??
      Object.values(secretKeys)[0];

    if (!url) {
      throw new Error("Supabase URL is not configured.");
    }

    if (!serviceKey) {
      throw new Error("Supabase server secret key is not configured.");
    }

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false },
    });

    // The database RPC is authoritative. Do not let a Realtime broadcast
    // failure turn a successful game action into an HTTP error.
    const { data: result, error } = await admin.rpc("game_action", {
      p_action: action,
      p_data: data,
    });

    if (error) {
      throw error;
    }

    if (result?.error) {
      return new Response(JSON.stringify({ error: result.error }), {
        status: 400,
        headers: { ...cors, "Content-Type": "application/json" },
      });
    }

    const roomCode = result?.code || data?.code;

    if (roomCode && action !== "get_state") {
      const channel = admin.channel(`room:${roomCode}`, {
        config: { private: false },
      });

      try {
        // httpSend takes the event name and payload as separate arguments.
        // The payload is always a non-null object.
        await channel.httpSend("state_changed", {
          action: String(action ?? "unknown"),
          at: new Date().toISOString(),
        });
      } catch (broadcastError) {
        // Clients also poll get_state, so broadcast delivery is only an
        // optimization and must never fail the underlying game action.
        console.warn("Quiz Race Realtime broadcast failed; polling will recover:", broadcastError);
      } finally {
        // Best-effort cleanup; cleanup errors must also remain non-fatal.
        try {
          await admin.removeChannel(channel);
        } catch (cleanupError) {
          console.warn("Quiz Race Realtime channel cleanup failed:", cleanupError);
        }
      }
    }

    return new Response(JSON.stringify(result), {
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unexpected server error";

    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
