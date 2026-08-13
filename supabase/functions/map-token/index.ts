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
// JWT-gated: verify_jwt stays TRUE for this function. Only a signed-in member
// of a couple gets a token, which bounds abuse to people who already have an
// account.
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
    const { data } = await admin
      .from("app_secrets")
      .select("value")
      .eq("key", "MAPBOX_PUBLIC_TOKEN")
      .maybeSingle();

    const token = data?.value ?? "";
    // An absent token is a configuration state, not an error. The client shows
    // "the map is not set up yet" rather than a broken grey rectangle, so the
    // app degrades into an explanation instead of a defect.
    return json({ token, configured: token.length > 0 });
  } catch (e) {
    console.error("map-token", e);
    return json({ token: "", configured: false });
  }
});
