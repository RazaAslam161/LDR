-- ───────────────────────────────────────────────────────────────────────────
-- Miles — security hardening, from a full audit of the live project.
--
-- Three findings, in descending order of how badly they would have gone.
-- ───────────────────────────────────────────────────────────────────────────

-- 1. prune_diag_events() DELETEs rows, and it was reachable at
--    /rest/v1/rpc/prune_diag_events by BOTH anon and authenticated. The anon
--    key ships inside the APK, so anyone holding a copy of the app could erase
--    the diagnostic trace — the one record built specifically to survive a
--    partner being 1,000km away. A retention job has exactly one caller,
--    pg_cron, which runs as the owner and does not need a grant.
revoke execute on function public.prune_diag_events() from public, anon, authenticated;

-- 2. A mutable search_path lets anyone who can create objects in a schema
--    earlier on the path shadow a function these bodies call. Both of these are
--    triggers that fire on rows every user writes: guard_couple_id on writes
--    that must stay inside a couple, presence_stamp_server_time on every
--    heartbeat.
alter function public.guard_couple_id() set search_path = public, pg_temp;
alter function public.presence_stamp_server_time() set search_path = public, pg_temp;

-- 3. RLS DOES NOT APPLY TO TRUNCATE. Supabase's stock setup grants ALL on every
--    public table to anon and authenticated and relies on RLS, which is sound
--    for select/insert/update/delete and silent about the one verb that empties
--    a table outright. PostgREST cannot emit TRUNCATE, so this was depth rather
--    than a live hole — but it sat one SQL-injection bug in any SECURITY
--    DEFINER function away from erasing the couple's entire history, and no
--    part of this app has ever used it.
--
--    TRIGGER (attach code to a table) and REFERENCES (constrain it) go with it
--    for the same reason: granted by default, never used, and each is a foothold.
--
--    Applied as a loop rather than a list so a table added later is covered by
--    re-running this file, and so it cannot silently miss one.
do $do$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public'
  loop
    execute format(
      'revoke truncate, trigger, references on public.%I from anon, authenticated',
      t.tablename);
  end loop;
end $do$;

-- ── Deliberately NOT changed, so the next audit does not re-litigate them ────
--
-- app_secrets has RLS on with zero policies. The linter calls that an issue; it
-- is the entire protection. RLS denies by default, so a table with no policy is
-- unreadable by any role that is not the owner, which is exactly right for
-- Cloudflare TURN credentials and the functions base URL.
--
-- pg_net is registered in the public schema and the linter says to move it. Its
-- callable surface already lives in the `net` schema — net.http_post is what
-- the push triggers call — so the move is cosmetic and risks the references
-- that actually deliver notifications.
--
-- Nineteen SECURITY DEFINER functions are executable by authenticated. That is
-- what they are for: create_couple, redeem_pairing_invite, ack_delivered,
-- delete_my_account and the rest exist precisely to do something RLS forbids
-- the caller from doing directly. Revoking them would break pairing, receipts
-- and account deletion. Each one checks auth.uid() itself.
-- ───────────────────────────────────────────────────────────────────────────
