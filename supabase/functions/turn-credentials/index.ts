import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// Mints short-lived WebRTC ICE (TURN) credentials from Cloudflare Realtime TURN.
// The Cloudflare key id + API token live ONLY in the service-role-locked
// `app_secrets` table (never in the app binary). JWT-gated: only signed-in
// couple members can call this.
//
// Secrets (set once in the DB, NOT in code):
//   insert into app_secrets(key,value) values
//     ('CF_TURN_KEY_ID', '<cloudflare turn key id>'),
//     ('CF_TURN_API_TOKEN', '<cloudflare turn api token>');

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data, error } = await admin
      .from("app_secrets")
      .select("key,value")
      .in("key", ["CF_TURN_KEY_ID", "CF_TURN_API_TOKEN"]);
    if (error) return json({ error: "secret_read_failed" }, 500);

    const map: Record<string, string> = {};
    for (const row of data ?? []) map[row.key as string] = row.value as string;
    const keyId = map["CF_TURN_KEY_ID"];
    const token = map["CF_TURN_API_TOKEN"];
    if (!keyId || !token) return json({ error: "turn_not_configured" }, 500);

    const ttl = 86400; // 24h
    const cf = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ttl }),
      },
    );
    const text = await cf.text();
    if (!cf.ok) {
      return json({ error: "cloudflare_error", status: cf.status, body: text }, 502);
    }
    // Pass Cloudflare's { iceServers: [...] } straight through.
    return new Response(text, {
      status: 200,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (e) {
    return json({ error: "exception", detail: String(e) }, 500);
  }
});
