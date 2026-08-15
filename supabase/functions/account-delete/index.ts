// ─────────────────────────────────────────────────────────────────────────────
// account-delete — the browser route to delete an account, which Play's Data
// Safety form requires to exist outside the app.
//
// In the app this is one delete_my_account RPC from a session that is already
// signed in. On the web there is no session and, for anyone who has already
// uninstalled, no way to make one the normal way — so identity is proved from
// the mailbox: ask for a code, receive it at the address on the account, spend
// it. Nothing here deletes on the strength of a request alone.
//
// The second step verifies the code and then calls delete_my_account on the
// session that verification returned. The RPC reads auth.uid(), so it must run
// on the caller's own JWT and not on the service role — which is also what
// makes it structurally unable to delete anyone else.
//
// verify_jwt is off: a browser arriving here has no token to present, and the
// anon key would not mean anything if it did. The mailbox is the gate, and
// Supabase Auth's own per-address and per-IP limits bound code requests.
//
// Operator setup: the Magic Link email template must contain {{ .Token }} or
// Auth sends a link instead of a code and step two has nothing to verify.
//
//   POST { email }         → { ok: true }  (always — see below)
//   POST { email, code }   → { ok: true } | 401 { error: "invalid_code" }
// ─────────────────────────────────────────────────────────────────────────────
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const { email, code } = await req.json();
    if (typeof email !== "string" || !email.includes("@")) {
      return json({ error: "bad_request" }, 400);
    }
    const anon = createClient(SUPABASE_URL, ANON_KEY);

    if (!code) {
      // shouldCreateUser:false, or asking to delete an address creates the
      // account it was asking to delete. The answer is the same either way: an
      // endpoint that says "no such user" tells a stranger which addresses are
      // on a couples app, which is most of what anyone would come here to ask.
      await anon.auth.signInWithOtp({
        email,
        options: { shouldCreateUser: false },
      });
      return json({ ok: true });
    }

    const { data } = await anon.auth.verifyOtp({
      email,
      token: String(code),
      type: "email",
    });
    const accessToken = data?.session?.access_token;
    if (!accessToken) return json({ error: "invalid_code" }, 401);

    const caller = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    });
    const { error } = await caller.rpc("delete_my_account");
    if (error) {
      // The RPC cascades a couple's whole history and can time out on a large
      // one. Saying so is the difference between the user trying again and the
      // user believing they are deleted when they are not.
      console.error("delete_my_account failed", error.message);
      return json({ error: "delete_failed" }, 500);
    }
    return json({ ok: true });
  } catch (e) {
    console.error("account-delete", e);
    return json({ error: "bad_request" }, 400);
  }
});
