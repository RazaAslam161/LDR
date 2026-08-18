// ─────────────────────────────────────────────────────────────────────────────
// reach-notify — Miles "Reach" push (Phase 5).
//
// Invoked by a Database Webhook on INSERT to public.reach_events. Sends an FCM
// HTTP v1 DATA message to the *recipient* partner's device so the app's own
// background handler can build the full-screen-intent notification (data-only
// is deliberate — notification-only messages are drawn by the OS and won't
// reliably wake the screen on our channel).
//
// Auth model: legacy fcm/send is DEAD. We mint an OAuth2 access token from the
// service-account JSON (RS256 JWT → Google token endpoint), scope
// firebase.messaging, then POST to v1/projects/{id}/messages:send.
//
// Required Supabase secrets (set by the operator — never commit):
//   FCM_SERVICE_ACCOUNT  = full service-account JSON (one line)
//   FCM_PROJECT_ID       = Firebase project id
// Auto-injected by the platform: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Recipient lookup uses public.profiles.couple_id (this app links couples via
// profiles.couple_id — there is NO couple_members table).
//
// ── kind 'msg_sync' — the silent delivery wake ───────────────────────────────
// Every other kind here exists to INTERRUPT someone. 'msg_sync' exists to
// interrupt nobody: it carries no title, no body and no notification block, and
// the only thing the receiving client does with it is call ack_delivered(seq)
// so the sender's one grey tick becomes two. It is what makes "my phone was
// offline, I got signal back, and it went double-tick without me touching the
// app" true, because FCM queues an undeliverable data message and hands it over
// on reconnect.
//
// It is deliberately NOT kind 'message'. 'message' is a live wire: every
// handset already in the field draws a visible banner for it — the `type ==
// 'message'` branch of firebaseMessagingBackgroundHandler calls
// showMessageNotification (reach_notifications.dart) — and those builds are
// sideloaded with no update channel, so that branch is permanent. The owner
// does not want message notifications. 'msg_sync' is a string those clients
// have never heard of, so it falls off the end of that handler's opening
// allow-list and returns before it even calls Firebase.initializeApp — no
// banner, no channel, no work. Reusing 'message' would have handed a banner to
// every installed phone.
// ─────────────────────────────────────────────────────────────────────────────
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FCM_PROJECT_ID = Deno.env.get("FCM_PROJECT_ID")!;
const SERVICE_ACCOUNT = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "{}");

const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

// The shared secret the triggers send, read once per instance. Cached because
// this runs on every push and the value only changes when an operator rotates
// it, at which point the instance is replaced anyway.
let _secret: string | null | undefined;
async function notifySecret(): Promise<string | null> {
  if (_secret !== undefined) return _secret ?? null;
  const { data } = await admin
    .from("app_secrets")
    .select("value")
    .eq("key", "NOTIFY_SHARED_SECRET")
    .maybeSingle();
  _secret = data?.value ?? null;
  return _secret ?? null;
}

// Constant time. `!==` stops at the first byte that differs, and this endpoint
// will answer as many guesses as anyone cares to send it.
function secretMatches(got: string | null, expected: string): boolean {
  const a = new TextEncoder().encode(got ?? "");
  const b = new TextEncoder().encode(expected);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ── base64url helpers ────────────────────────────────────────────────────────
function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const b64urlStr = (s: string) => b64url(new TextEncoder().encode(s));

function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const der = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) der[i] = bin.charCodeAt(i);
  return der;
}

// ── OAuth2: service-account JWT → access token ───────────────────────────────
// Cached for the life of the instance, less a minute of clock skew. This used
// to sign a fresh RS256 JWT and round-trip Google on EVERY push, which was
// merely wasteful while pushes were one-per-Reach. Message delivery wakes are
// one per message, so a ten-message burst meant ten key imports and ten token
// exchanges to send ten payloads that are ~120 bytes each — the auth cost was
// about to dwarf the send.
//
// The in-flight promise is cached, not just the result, so a burst that arrives
// on a cold instance mints once and the rest await it rather than each starting
// their own exchange. A rejection clears the cache so the next push retries
// instead of inheriting a permanently poisoned one.
let _token: { value: string; expiresAt: number } | null = null;
let _tokenInFlight: Promise<string> | null = null;

function getAccessToken(): Promise<string> {
  if (_token && Date.now() < _token.expiresAt) return Promise.resolve(_token.value);
  if (_tokenInFlight) return _tokenInFlight;
  _tokenInFlight = mintAccessToken()
    .then((t) => {
      _tokenInFlight = null;
      return t;
    })
    .catch((e) => {
      _tokenInFlight = null;
      throw e;
    });
  return _tokenInFlight;
}

async function mintAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: SERVICE_ACCOUNT.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${b64urlStr(JSON.stringify(header))}.${b64urlStr(JSON.stringify(claims))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(SERVICE_ACCOUNT.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      key,
      new TextEncoder().encode(unsigned),
    ),
  );
  const jwt = `${unsigned}.${b64url(sig)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) {
    throw new Error(`token exchange failed: ${res.status} ${await res.text()}`);
  }
  const body = await res.json();
  const token = body.access_token as string;
  // Google returns expires_in seconds (3600). Hold it 60s short of that so a
  // token can never expire mid-flight between this check and FCM reading it.
  const ttlSec = typeof body.expires_in === "number" ? body.expires_in : 3600;
  _token = { value: token, expiresAt: Date.now() + Math.max(ttlSec - 60, 30) * 1000 };
  return token;
}

// ── handler ──────────────────────────────────────────────────────────────────
// Every outcome answers identically.
//
// The caller's own client can read this endpoint's effects, so a body that
// distinguishes "sent" from "no recipient token" from an FCM error is a
// reachability oracle wearing a JSON hat. The trigger is fire-and-forget
// (net.http_post from an AFTER INSERT) and reads none of this; the detail that
// used to be here goes to the log and to push_failures, where only the service
// role can see it.
const OK = () =>
  new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  try {
    // verify_jwt is off, and correctly so: every caller is a database trigger
    // and a trigger has no JWT. That also meant this endpoint took orders from
    // the open internet — it holds the service role, looks up whoever the body
    // names, and pushes them a notification. On a build that disguises itself
    // as a news app, that is a usable phishing channel.
    //
    // The triggers now carry a secret minted in the database. No secret
    // configured means no caller can be told apart from an attacker, so the
    // answer is 403: a restored project sends nothing until an operator seeds
    // app_secrets, which is the failure that gets noticed rather than the one
    // that does not.
    const expected = await notifySecret();
    if (!expected || !secretMatches(req.headers.get("x-notify-secret"), expected)) {
      return new Response(JSON.stringify({ error: "forbidden" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    }
    const payload = await req.json();
    // Our triggers deliver { kind, record }. Bare rows (an older reach trigger
    // that posted to_jsonb(new) directly) still work and default to "reach".
    const kind:
      | "reach"
      | "care"
      | "call"
      | "message"
      | "memory"
      | "ritual"
      | "msg_sync" = payload.kind ?? payload.type ?? "reach";
    const row = payload.record ?? payload;
    const coupleId: string | undefined = row?.couple_id;

    // Calls name the two sides explicitly (caller_id/callee_id); reach and care
    // use from_user and the recipient is simply the other member of the couple.
    // Messages name their author sender_id; calls name both sides explicitly;
    // a memory names its proposer; reach/care use from_user and the recipient
    // is the other couple member.
    const fromUser: string | undefined = kind === "call"
      ? row?.caller_id
      : kind === "message" || kind === "msg_sync"
      ? row?.sender_id
      : kind === "memory"
      ? row?.proposer
      : row?.from_user;
    // A ritual has no author — the couple set it, and it goes to BOTH of them.
    // The worker addresses each partner in its own call rather than this
    // function fanning out, so the recipient block below stays exactly as the
    // other five kinds have always used it.
    const explicitRecipient: string | undefined = kind === "call"
      ? row?.callee_id
      : kind === "ritual"
      ? payload.recipient
      : undefined;
    const rowId: string = row?.id ?? "";

    if (!coupleId || (!fromUser && kind !== "ritual")) {
      return new Response(JSON.stringify({ error: "bad payload" }), { status: 400 });
    }
    if (kind === "ritual" && !explicitRecipient) {
      return new Response(JSON.stringify({ error: "ritual needs a recipient" }), {
        status: 400,
      });
    }

    // Fail clearly if the service-account secret isn't configured (otherwise the
    // JWT signing throws a cryptic "undefined.replace" later).
    if (!SERVICE_ACCOUNT.private_key || !SERVICE_ACCOUNT.client_email) {
      console.error(
        "FCM_SERVICE_ACCOUNT secret missing/invalid — set it via `supabase secrets set`",
      );
      return new Response(
        JSON.stringify({ error: "FCM_SERVICE_ACCOUNT not configured" }),
        { status: 200 },
      );
    }
    if (!FCM_PROJECT_ID) {
      return new Response(
        JSON.stringify({ error: "FCM_PROJECT_ID not configured" }),
        { status: 200 },
      );
    }

    // Recipient: the explicit callee for a call, otherwise the OTHER member of
    // the couple.
    const recipientQuery = admin.from("profiles").select("id, fcm_token");
    const { data: recipients, error: recipientErr } = explicitRecipient
      ? await recipientQuery.eq("id", explicitRecipient).limit(1)
      : await recipientQuery.eq("couple_id", coupleId).neq("id", fromUser).limit(1);
    if (recipientErr) {
      // A failed lookup is NOT "partner has no token". That exit below is
      // silent by design, and a transient PostgREST failure was taking it —
      // a missed call ring with no log and no push_failures row, identical
      // from the outside to a contact pause. Record it against the one id
      // this path still holds; the FCM-failure branch further down is the
      // model.
      console.error("recipient lookup failed", kind, recipientErr.message);
      await admin.from("push_failures").insert({
        user_id: explicitRecipient ?? fromUser,
        kind,
        reason: "recipient_lookup_failed",
      });
      return OK();
    }
    const recipient = recipients?.[0];
    if (!recipient?.fcm_token) {
      return OK();
    }

    const accessToken = await getAccessToken();
    const message = {
      message: {
        token: recipient.fcm_token,
        // DATA-only: the Android background handler builds the notification (and
        // wears this device's disguise). The keys per kind match exactly what
        // fcm_service.dart / firebaseMessagingBackgroundHandler read.
        //
        // No from_name, for any kind. Every notification is built on the
        // RECEIVING device wearing that device's disguise, and the client falls
        // back to "Your partner" wherever the key is missing
        // (fcm_service.dart:199, :267, :291, reach_notifications.dart:388,
        // :449) — so sending it only put the partner's real display name
        // through Google in cleartext to be thrown away at the far end. That
        // was already the reasoning for call/memory/ritual; it was never
        // narrower than that.
        data: {
          type: kind,
          couple_id: coupleId,
          ...(kind === "reach" ? { reach_id: rowId } : {}),
          ...(kind === "care" ? { nudge_id: rowId } : {}),
          ...(kind === "call"
            ? { call_id: rowId, video: String(row?.video === true) }
            : {}),
          ...(kind === "message" ? { message_id: rowId } : {}),
          ...(kind === "memory" ? { memory_id: rowId } : {}),
          ...(kind === "ritual" ? { ritual_id: rowId } : {}),
          // seq, and never the body. The receiving client needs exactly one
          // number to answer with — ack_delivered(seq) — and FCM data values
          // are map<string,string>, so a bigint from jsonb must be stringified
          // here or the send is rejected outright.
          ...(kind === "msg_sync"
            ? { message_id: rowId, seq: String(row?.seq ?? "") }
            : {}),
        },
        // A call is worthless if it arrives late, but a MESSAGE must survive a
        // doze window or an offline stretch — a 30s TTL made FCM discard it
        // rather than queue it, so a backgrounded partner simply never got it.
        //
        // A memory proposal is the least urgent thing here and the one with the
        // longest useful life: it waits for the partner however long that
        // takes, and dropping it after thirty seconds is precisely how nine of
        // them ended up waiting forever.
        android: {
          priority: "high",
          // A ritual is the least urgent and the longest-lived of all of them:
          // it is worth having whenever the phone next comes back, and a 30s
          // TTL would drop it for anyone whose handset was dozing at 10 PM —
          // which is most people, at 10 PM.
          ttl: kind === "message" || kind === "memory" || kind === "ritual" ||
              kind === "msg_sync"
            ? "86400s"
            : "30s",
          // A delivery wake is worth exactly as much as the newest one. Ten
          // messages sent while the partner's phone is offline queue ten
          // identical "go ack yourself" pokes; FCM keeps only the last per
          // collapse_key and drops the rest, so reconnecting costs one wakeup
          // instead of ten.
          //
          // This is only safe because the receipt is a high-water mark:
          // ack_delivered() stores greatest(existing, incoming), so acking the
          // newest seq marks every earlier message delivered too. Collapsing a
          // counter would lose writes; collapsing a maximum cannot.
          //
          // Scoped per couple, because the key is global to the app on that
          // device and two couples' wakes must never evict each other.
          ...(kind === "msg_sync" ? { collapse_key: `msg:${coupleId}` } : {}),
        },
        // The wake is silent on iOS too: content-available with no sound and no
        // alert. apns-priority 10 is for something the user should see and
        // Apple throttles it for background-only payloads — 5 is the correct
        // priority for a push whose entire job is to hand the app a few CPU
        // cycles.
        apns: kind === "msg_sync"
          ? {
            headers: { "apns-priority": "5", "apns-push-type": "background" },
            payload: { aps: { "content-available": 1 } },
          }
          : {
            headers: { "apns-priority": "10" },
            payload: { aps: { sound: "default", "content-available": 1 } },
          },
      },
    };

    const fcmRes = await fetch(
      `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(message),
      },
    );

    if (!fcmRes.ok) {
      const errText = await fcmRes.text();
      // A dead token is recorded, NOT nulled on the profile.
      //
      // profiles is selected whole by the partner's own client
      // (supabase_repository.fetchPartner does .select()), so nulling fcm_token
      // here let the caller watch it go non-null -> null as a direct
      // consequence of their own call: "their app has been uninstalled,
      // reinstalled or cleared", delivered on demand, one call at a time.
      // push_failures is service-role only. The client re-registers its token
      // on every resume, which is what actually heals a stale one.
      const dead = fcmRes.status === 404 ||
        errText.includes("UNREGISTERED") ||
        errText.includes("NOT_FOUND");
      await admin.from("push_failures").insert({
        user_id: recipient.id,
        kind,
        status: fcmRes.status,
        reason: dead ? "unregistered" : "send_failed",
      });
      console.error("FCM send failed", fcmRes.status, errText);
      // 200 so the webhook doesn't retry-storm; we've logged + cleaned up.
      return OK();
    }

    return OK();
  } catch (e) {
    console.error("reach-notify error", e);
    return OK();
  }
});
