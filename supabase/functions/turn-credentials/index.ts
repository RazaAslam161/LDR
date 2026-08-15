import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// Mints short-lived WebRTC ICE (TURN) credentials from Cloudflare Realtime TURN.
// The Cloudflare key id + API token live ONLY in the service-role-locked
// `app_secrets` table (never in the app binary).
//
// verify_jwt is satisfied by the anon key, which ships inside an APK anyone can
// unzip — so on its own it proves nothing about the caller, and this endpoint
// spends someone else's Cloudflare bill by the gigabyte. The caller's own JWT
// is checked here the way map-token does it, which bounds minting to people who
// hold an account. How many one account may mint is bounded by
// claim_turn_mint(), which keeps the counter this function has nowhere to hold:
// ten an hour, counted against auth.uid() on the caller's own client so there is
// no user id on the wire to substitute.
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
    const authHeader = req.headers.get("Authorization") ?? "";
    const caller = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: "unauthenticated" }, 401);

    // Ten mints an hour per account. Deliberately on `caller`, not `admin`: the
    // RPC reads auth.uid(), so the identity being counted is the one the JWT
    // proved, and nothing here can be pointed at somebody else's quota.
    //
    // A missing or broken RPC lets the mint through and says so in the log. The
    // failure this guards is a Cloudflare invoice; the failure it would cause by
    // closing is every call on a fleet with no update channel, on the day a
    // migration has not reached this project yet. Cost is the cheaper loss.
    const { data: minted, error: mintErr } = await caller.rpc("claim_turn_mint");
    if (mintErr) {
      console.error("claim_turn_mint failed, allowing mint", mintErr.message);
    } else if (minted === false) {
      return json({ error: "rate_limited" }, 429);
    }

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

    // 24h, and it has to stay 24h until the app stops outliving it: the client
    // serves _cachedTurn for 12h without asking again and restores credentials
    // up to 20h old from disk (call_controller.dart:438, :469). A shorter TTL
    // would hand every one of those calls a credential Cloudflare has already
    // expired, on a fleet with no update channel. Lower it once a build that
    // caches for less than the new TTL is enforced by app_release.min_build.
    const ttl = 86400;
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

    // NORMALISE THE SHAPE HERE. This is the two-month calling bug.
    //
    // Cloudflare's generate-ice-servers returns `iceServers` as a single
    // OBJECT ({urls:[...], username, credential}), not an array. This function
    // used to pass the body straight through on the assumption it was an
    // array, and the client rejected anything that was not a List — so
    // _cachedTurn stayed empty forever, no relay candidate ever entered a peer
    // connection, and every call between two different networks failed while
    // two phones on one wifi worked perfectly on host candidates.
    //
    // The contract the client depends on is guaranteed server-side now, and
    // both shapes are accepted so this keeps working if Cloudflare changes it.
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return json({ error: "cloudflare_bad_json", body: text.slice(0, 500) }, 502);
    }
    const rawServers = (parsed as { iceServers?: unknown })?.iceServers;
    const iceServers = Array.isArray(rawServers)
      ? rawServers
      : rawServers && typeof rawServers === "object"
      ? [rawServers]
      : [];
    if (iceServers.length === 0) {
      return json({ error: "cloudflare_no_ice_servers", body: text.slice(0, 500) }, 502);
    }
    return json({ iceServers });
  } catch (e) {
    return json({ error: "exception", detail: String(e) }, 500);
  }
});
