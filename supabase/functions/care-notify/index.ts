// ─────────────────────────────────────────────────────────────────────────────
// care-notify — retired. Answers 410 and does nothing else.
//
// This was a second copy of reach-notify that only knew about care nudges, and
// nothing ever called it: care_nudges' AFTER INSERT trigger runs notify_care(),
// which posts to /functions/v1/reach-notify with kind 'care' and the shared
// secret. So the only thing this endpoint still did was take couple_id,
// from_user and message from whoever asked and push that text to a partner's
// phone with the service role — no secret, no membership check, and two
// different 200 bodies that told the caller whether the target had a token.
//
// Deleting the file here would leave the last deployed version serving forever
// — a slug goes away only when the Management API is told to delete it, which
// nothing in this repo does. So the tombstone is what actually retires the
// behaviour, and 410 is the honest answer for anything that still has the URL.
// ─────────────────────────────────────────────────────────────────────────────
Deno.serve(() =>
  new Response(JSON.stringify({ error: "gone" }), {
    status: 410,
    headers: { "Content-Type": "application/json" },
  })
);
