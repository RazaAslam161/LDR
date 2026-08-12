// call-notify — Tethered incoming-call push. FCM HTTP v1 + service account.
// Invoked by a DB Webhook on INSERT to public.call_invites. Sends a high-priority
// DATA message so the callee's app (even if closed) rings via its background
// handler. Secrets: FCM_SERVICE_ACCOUNT (service-account JSON), FCM_PROJECT_ID.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FCM_PROJECT_ID = Deno.env.get("FCM_PROJECT_ID") ?? "";
const SERVICE_ACCOUNT = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "{}");

const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

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

async function getAccessToken(): Promise<string> {
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
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned)),
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
  if (!res.ok) throw new Error(`token exchange failed: ${res.status} ${await res.text()}`);
  return (await res.json()).access_token as string;
}

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const row = payload.record ?? payload;
    const callerId: string | undefined = row?.caller_id;
    const calleeId: string | undefined = row?.callee_id;
    const coupleId: string | undefined = row?.couple_id;
    const callId: string = row?.id ?? "";
    const video = row?.video === true || row?.video === "true";
    if (!callerId || !calleeId || !coupleId) {
      return new Response(JSON.stringify({ error: "bad payload" }), { status: 400 });
    }

    const { data: recipient } = await admin
      .from("profiles").select("id, fcm_token").eq("id", calleeId).single();
    if (!recipient?.fcm_token) {
      return new Response(JSON.stringify({ skipped: "no recipient token" }), { status: 200 });
    }

    const { data: sender } = await admin
      .from("profiles").select("display_name").eq("id", callerId).single();
    const fromName: string = sender?.display_name ?? "Your partner";

    const accessToken = await getAccessToken();
    const message = {
      message: {
        token: recipient.fcm_token,
        data: {
          type: "call",
          from_name: fromName,
          couple_id: coupleId,
          call_id: callId,
          video: String(video),
        },
        android: { priority: "high", ttl: "45s" },
        apns: {
          headers: { "apns-priority": "10" },
          payload: { aps: { sound: "default", "content-available": 1 } },
        },
      },
    };
    const fcmRes = await fetch(
      `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        body: JSON.stringify(message),
      },
    );
    if (!fcmRes.ok) {
      const errText = await fcmRes.text();
      if (fcmRes.status === 404 || errText.includes("UNREGISTERED") || errText.includes("NOT_FOUND")) {
        await admin.from("profiles").update({ fcm_token: null }).eq("id", recipient.id);
      }
      console.error("call-notify FCM failed", fcmRes.status, errText);
      return new Response(JSON.stringify({ error: errText }), { status: 200 });
    }
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  } catch (e) {
    console.error("call-notify error", e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 200 });
  }
});
