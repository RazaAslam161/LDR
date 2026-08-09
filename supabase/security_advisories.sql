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
-- Guarded individually. A bare REVOKE on a function that does not exist raises
-- 42883, and the SQL editor runs a pasted script as ONE transaction — so on a
-- database lacking any one of these (notify_care_nudge is created by no file in
-- this repo) the whole script rolled back and every other revoke silently did
-- nothing, while appearing to succeed.
do $$
declare fn text;
begin
  foreach fn in array array[
    'init_presence_on_profile()', 'sync_presence_couple_id()',
    'notify_call()', 'notify_care()', 'notify_care_nudge()', 'notify_reach()'
  ] loop
    begin
      execute format(
        'revoke execute on function public.%s from public, anon, authenticated', fn);
    exception when undefined_function then
      raise notice 'skipped: public.% does not exist here', fn;
    end;
  end loop;
end $$;

-- pg_net out of public. Its callable functions live in the net.* schema
-- regardless, so the FCM triggers (net.http_post) are unaffected; this only
-- moves where the extension object itself is registered.
--
-- Deliberately NOT wrapped in a drop/recreate fallback. Some pg_net builds
-- are not relocatable, and dropping the extension takes the net schema with
-- it — every push notification in the app rides on net.http_post. A raised
-- notice is the right outcome there; losing push to satisfy a linter is not.
create schema if not exists extensions;
do $$
begin
  alter extension pg_net set schema extensions;
exception when others then
  raise notice 'pg_net not relocatable (%). Left in public — push still works.',
    sqlerrm;
end $$;
