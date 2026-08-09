-- ───────────────────────────────────────────────────────────────────────────
-- Miles — Supabase linter advisories, 2026-08. Safe to re-run.
--
-- The long "authenticated can execute SECURITY DEFINER" list is deliberately
-- NOT touched: those functions ARE the app's API (hide_message,
-- join_couple_by_code, the vault pins, ...) and each gates on auth.uid()
-- internally. Revoking them breaks the app.
-- ───────────────────────────────────────────────────────────────────────────

-- Trigger functions. Fired by postgres on row events; they were never meant
-- to be callable over /rest/v1/rpc, they just inherited the default EXECUTE
-- grant every function gets. Postgres checks EXECUTE only at CREATE TRIGGER
-- time, so the existing triggers keep firing after the revoke.
revoke execute on function public.init_presence_on_profile()  from public, anon, authenticated;
revoke execute on function public.sync_presence_couple_id()   from public, anon, authenticated;
revoke execute on function public.notify_call()               from public, anon, authenticated;
revoke execute on function public.notify_care()               from public, anon, authenticated;
revoke execute on function public.notify_care_nudge()         from public, anon, authenticated;
revoke execute on function public.notify_reach()              from public, anon, authenticated;

-- pg_net out of public. Its callable functions live in the net.* schema
-- regardless, so the FCM triggers (net.http_post) are unaffected; this only
-- moves where the extension object itself is registered. Older pg_net
-- versions are not relocatable — for those, drop and recreate (the net
-- schema and its functions are rebuilt; only queued-but-unsent http requests
-- are lost, which for push notifications is nothing).
create schema if not exists extensions;
do $$
begin
  begin
    alter extension pg_net set schema extensions;
  exception when others then
    drop extension if exists pg_net;
    create extension pg_net with schema extensions;
  end;
end $$;
