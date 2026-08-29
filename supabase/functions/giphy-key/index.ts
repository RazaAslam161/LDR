// giphy-key — hands a signed-in device the Giphy API key from the
// `app_secrets` table, so it is never in the app binary.
//
// Same shape and same reasoning as map-token. GiphyService has fetched its key
// from here since it stopped reading dotenv — but this function was never
// written and no GIPHY row was ever seeded, so `functions.invoke('giphy-key')`
// threw, GiphyService caught it into an empty key, and the picker rendered an
// empty grid. GIFs were not "off"; they were failing silently, and nothing on
// the screen said so. That is the defect this file closes.
//
// The key is billable rather than cryptographically secret, which is exactly
// the map-token argument: this app ships as an artifact anyone can unzip, a key
// lifted from `strings` spends someone else's quota, and a key in
// `app_secrets` is rotated with one UPDATE instead of a build to a fleet that
// may not update.
//
// Seed it with:
//   insert into app_secrets(key, value)
//   values ('GIPHY_API_KEY', '…')
//   on conflict (key) do update set value = excluded.value;
//
// JWT-gated: verify_jwt stays TRUE. Holding a signed-in account is the bound,
// the same bound map-token starts from.
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    // The caller's own JWT, not the service role. supabase-js verifies it, so
    // an unsigned request cannot reach the secret.
    const authHeader = req.headers.get("Authorization") ?? "";
    const caller = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: "unauthenticated" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );
    const { data, error } = await admin
      .from("app_secrets")
      .select("value")
      .eq("key", "GIPHY_API_KEY")
      .maybeSingle();
    // A read that FAILED is not an answer, and answering 200 turned it into
    // one. supabase-js returns PostgREST failures in the envelope instead of
    // throwing, so the catch below never saw them and `?? ""` collapsed them
    // into "nobody seeded the key" — while GiphyService latches _resolved on
    // any parseable 200 (giphy_service.dart:86), which is the very latch its
    // author's comment says must not close over a transient failure. One
    // database hiccup therefore pinned "GIFs are not set up yet" for the whole
    // app process, with nothing logged on either side. A 5xx is what runs the
    // client's retryable path: functions.invoke throws on it, _resolved stays
    // false, and the next picker open asks again. Same shape as map-token, one
    // directory over.
    if (error) {
      console.error("app_secrets read failed for GIPHY_API_KEY", error.message);
      return json({ error: "secret_read_failed" }, 500);
    }

    const key = data?.value ?? "";
    // An absent key is a configuration state, not an error — `configured` lets
    // the picker say "GIFs are not set up yet" instead of showing an empty grid
    // that looks like a search returning nothing.
    return json({ key, configured: key.length > 0 });
  } catch (e) {
    console.error("giphy-key", e);
    // Not `configured: false`. Anything that threw on the way here — the JWT
    // check, the client construction — is a failure of ours, and handing it
    // back as a 200 told the client "there is no key" with the same authority
    // as a read that succeeded, latching it for the process.
    return json({ error: "giphy_key_failed" }, 500);
  }
});
