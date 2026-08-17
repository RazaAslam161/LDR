// ─────────────────────────────────────────────────────────────────────────────
// reap-storage — actually deletes the blobs behind deleted rows.
//
// WHY THIS EXISTS AT ALL, and why the SQL it replaces was worse than nothing:
//
// storage.objects carries a `version` column, and Supabase stores the physical
// file at <bucket>/<name>/<version>. That version string exists ONLY in that
// row. So `delete from storage.objects` does not delete a file — it destroys
// the only pointer to it. The bytes stay in the backing store, permanently
// unreachable, permanently billed, and permanently un-erasable, which is the
// exact opposite of what every caller believed it was doing.
//
// Two callers believed it:
//   * reap_storage_objects(), draining the memory-photo reap queue
//   * delete_my_account(), erasing a whole couple's media when the last member
//     leaves — so "delete my account" left every photograph on the server.
//
// The Storage API deletes the row AND the object, so the drain has to go
// through it, which needs the service role, which means an edge function.
//
// Auth: verify_jwt is off because the caller is pg_cron via net.http_post and a
// cron job has no JWT. The shared secret the triggers already use is enforced
// instead — this holds the service role and deletes things, so it must not take
// orders from the open internet.
// ─────────────────────────────────────────────────────────────────────────────
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(SUPABASE_URL, SERVICE_ROLE);

/// Storage `remove` takes a list; keep each call well inside any request limit.
const BATCH = 100;

/// Bounded per invocation. A queue that has grown large after an outage should
/// drain over several nightly runs rather than time out on every one of them
/// and never make progress.
const MAX_PER_RUN = 2000;

let _secret: string | null | undefined;
async function notifySecret(): Promise<string | null> {
  if (_secret !== undefined) return _secret;
  const { data } = await admin
    .from("app_secrets")
    .select("value")
    .eq("key", "NOTIFY_SHARED_SECRET")
    .maybeSingle();
  _secret = data?.value ?? null;
  return _secret;
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

const OK = (drained: number) =>
  new Response(JSON.stringify({ ok: true, drained }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  try {
    // No secret configured means no caller can be told apart from an attacker,
    // and this one deletes files. A restored project drains nothing until an
    // operator seeds app_secrets; the queue is durable and waits.
    const expected = await notifySecret();
    if (!expected || !secretMatches(req.headers.get("x-notify-secret"), expected)) {
      return new Response(JSON.stringify({ error: "forbidden" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    }

    const { data: queued, error: queueErr } = await admin
      .from("storage_reap")
      .select("bucket_id, name")
      .order("queued_at")
      .limit(MAX_PER_RUN);
    if (queueErr) {
      // A failed read used to fall into `!queued` and answer exactly like an
      // empty queue — a dead drain indistinguishable from a finished one.
      // Still 200 (the queue is durable and the hourly cron retries), but on
      // the record.
      console.error("queue read failed", queueErr.message);
      return OK(0);
    }

    if (!queued || queued.length === 0) return OK(0);

    // Group by bucket: remove() is per-bucket.
    const byBucket = new Map<string, string[]>();
    for (const row of queued) {
      const list = byBucket.get(row.bucket_id) ?? [];
      list.push(row.name);
      byBucket.set(row.bucket_id, list);
    }

    let drained = 0;
    for (const [bucket, names] of byBucket) {
      for (let i = 0; i < names.length; i += BATCH) {
        const slice = names.slice(i, i + BATCH);
        const { error } = await admin.storage.from(bucket).remove(slice);
        if (error) {
          // Leave the batch queued and try again on the next run. A transient
          // storage error must not silently drop the only record that these
          // objects are supposed to disappear.
          console.error("remove failed", bucket, error.message);
          continue;
        }
        // Dequeue only what actually went. An object already gone returns no
        // error, which is the outcome we want for a retried batch.
        const { error: dqErr } = await admin
          .from("storage_reap")
          .delete()
          .eq("bucket_id", bucket)
          .in("name", slice);
        if (dqErr) {
          // The objects are gone but the queue rows are not: the next run
          // re-reaps them harmlessly (remove() of a missing object is not an
          // error). Counting them as drained here would also silence the
          // shortfall log below while the queue quietly stopped shrinking.
          console.error("dequeue failed", bucket, dqErr.message);
          continue;
        }
        drained += slice.length;
      }
    }

    if (drained < queued.length) {
      // The per-batch errors above name the buckets; this names the size of
      // the shortfall, so "the drain is limping" is one log line, not a diff
      // of row counts across runs.
      console.error(`drained ${drained} of ${queued.length}; remainder left queued`);
    }
    return OK(drained);
  } catch (e) {
    console.error("reap-storage error", e);
    // 200 so a cron failure does not retry-storm; the queue is durable and the
    // next run picks up whatever is left.
    return OK(0);
  }
});
