// map-token — hands a signed-in device the Mapbox public token from the
// `app_secrets` table, so it is never in the app binary.
//
// Same shape and same reasoning as turn-credentials. A Mapbox public token is
// not a secret in the cryptographic sense — it travels in every tile request
// and Mapbox expects it to — but it IS billable, and this app is sideloaded as
// an APK anyone can unzip. A token lifted from `strings` runs up someone else's
// invoice against an account with no way to notice. Keeping it server-side
// means it can be rotated in one UPDATE without shipping a build to a fleet
// that has no update channel.
//
// Seed it with:
//   insert into app_secrets(key, value)
//   values ('MAPBOX_PUBLIC_TOKEN', 'pk.…')
//   on conflict (key) do update set value = excluded.value;
//
// JWT-gated: verify_jwt stays TRUE for this function. A signed-in ACCOUNT gets
// the token — there is no couple-membership check here, and this comment used
// to claim one. Holding an account is the whole bound, which is the same bound
// turn-credentials starts from.
//
// Unlike turn-credentials this is not rate-limited, and that is a decision
// rather than an omission: every caller receives the SAME long-lived Mapbox
// token, so an attacker who wants to spend the tile budget fetches it once and
// never comes back. Counting the fetches would bound nothing. What bounds this
// is rotating the row in app_secrets, which is why the token lives there.
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
      .eq("key", "MAPBOX_PUBLIC_TOKEN")
      .maybeSingle();
    // A read that FAILED is not an answer, and answering 200 turned it into
    // one. supabase-js returns PostgREST failures in the envelope instead of
    // throwing, so the catch below never saw them and `?? ""` collapsed them
    // into "nobody seeded the token" — while MapToken.ensure pins _fetched on
    // any parseable 200 (map_token.dart:44), which is exactly the latch its
    // author wrote that comment to prevent. One transient database error
    // therefore pinned "the map is not set up yet" for the whole app process.
    // A 5xx is what runs the client's retryable path. Same shape as
    // turn-credentials, one directory over.
    if (error) {
      console.error(
        "app_secrets read failed for MAPBOX_PUBLIC_TOKEN",
        error.message,
      );
      return json({ error: "secret_read_failed" }, 500);
    }

    const token = data?.value ?? "";
    // An absent token is a configuration state, not an error. The client shows
    // "the map is not set up yet" rather than a broken grey rectangle, so the
    // app degrades into an explanation instead of a defect.
    return json({ token, configured: token.length > 0 });
  } catch (e) {
    console.error("map-token", e);
    // Not `configured: false`. Anything that threw on the way here — the JWT
    // check, the client construction — is a failure of ours, and handing it
    // back as a 200 told the client "there is no token" with the same
    // authority as a read that succeeded, latching it for the process.
    return json({ error: "map_token_failed" }, 500);
  }
});
