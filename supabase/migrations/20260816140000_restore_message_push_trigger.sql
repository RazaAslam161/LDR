-- ───────────────────────────────────────────────────────────────────────────
-- Miles — re-attach message_notify_on_insert to public.messages.
--
-- WHY IT IS MISSING. Production carries ZERO triggers on public.messages,
-- while call_invites, reach_events and care_nudges carry two each.
-- public.notify_message() is present and current; nothing calls it.
--
-- It was not dropped by any file in this directory. 20260601003100 is the only
-- migration that names the trigger and it CREATES it. The drop was applied to
-- production out of band and exists only in the prod ledger, as version
-- 20260812013012 `no_message_push` — a migration with no file here, no commit,
-- and no line in BRAIN.md giving a reason. It is described in exactly one
-- place: docs/guides/PRODUCTION-AUDIT-2026-08-15.md, which refuted a reported
-- per-message push fanout on the grounds that the trigger no longer exists.
--
-- The trigger WAS live before that. Commit 8302bce (2026-08-11) traced a real
-- message push end to end — "Every hop worked - trigger, edge function, FCM,
-- the background isolate, the notification" — and argued in the same breath
-- that "killing the trigger would hand back 'she never texted me / the app is
-- broken' to every couple". It was killed the following day regardless, inside
-- the window that was fixing cross-couple push leakage (ce5a902, c504979).
-- Whether that was deliberate containment or collateral is not recorded
-- anywhere; the ledger row's `statements` column is the only thing that can
-- still answer it.
--
-- WHY 003100 NEVER PUT IT BACK. Production was baselined on 2026-08-10 with
-- `supabase migration repair --status applied` (commit 194f134; see
-- migrations/README.md, "Baselining an existing production database"), so every
-- 20260601* version is recorded as applied and can never replay. On top of
-- that, `supabase db push` is not this project's deployment mechanism at all —
-- the prod ledger records migrations under names and timestamps that do not
-- match these filenames (PLAY-RELEASE-RUNBOOK §1.5). Nothing was ever going to
-- re-create it. A fresh database replays 003100 and gets the trigger, which is
-- why the repo and production disagree and only production is wrong.
--
-- WHAT RESTORING IT TURNS ON, beyond the push itself: as of 20260816120000,
-- notify_message() consults public.push_muted(couple_id, sender_id, 'message'),
-- so re-attaching this trigger is ALSO the moment the contact pause begins
-- covering messages. Until now the pause covered reaches, nudges and calls
-- only, because the message channel had no trigger for the guard to sit in.
-- That coupling is the precondition below: this file REFUSES to run against a
-- database whose notify_message() has not been replaced by 20260816120000,
-- because restoring an unguarded message push would hand a paused contact back
-- the one channel they could still interrupt with.
--
-- This is a behaviour change, not a no-op. Afterwards every INSERT into
-- public.messages fires one pg_net POST to reach-notify, and backgrounded
-- handsets receive message notifications again for the first time since
-- 2026-08-12.
--
-- Second run: no-op. `drop trigger if exists` followed by `create trigger`
-- re-creates the same trigger over itself.
-- ───────────────────────────────────────────────────────────────────────────

do $guard$
begin
  if coalesce((select pg_get_functiondef(p.oid) from pg_proc p
                where p.pronamespace = 'public'::regnamespace
                  and p.proname = 'notify_message'), '')
     not like '%push_muted%' then
    raise exception 'notify_message() does not consult push_muted - apply 20260816120000 before restoring message push';
  end if;
end $guard$;

drop trigger if exists message_notify_on_insert on public.messages;
create trigger message_notify_on_insert
after insert on public.messages
for each row execute function public.notify_message();

-- Verify after applying. pg_net is fire-and-forget and swallows the response,
-- so "the trigger fired" and "the push arrived" are two separate facts and both
-- have to be read:
--
--   select tgname, pg_get_triggerdef(oid) from pg_trigger
--    where tgrelid = 'public.messages'::regclass and not tgisinternal;
--   -- expect one row: message_notify_on_insert
--
--   -- then send one message with the other handset backgrounded
--   select status_code, content, created
--     from net._http_response order by created desc limit 10;
--   -- 200            reach-notify accepted it
--   -- 401 / 403      NOTIFY_SHARED_SECRET missing or wrong on one side
--   -- 404            reach-notify is not deployed under that name
--   -- no new row     the trigger did not fire, or the base URL is unset —
--   --                look for the 'notify_message: FUNCTIONS_BASE_URL unset'
--   --                warning in the Postgres logs
--
-- ───────────────────────────────────────────────────────────────────────────
-- ROLLBACK. Restores the state this file found: messages with no trigger,
-- message push off, the contact pause covering reach, care and call only.
--
--   drop trigger if exists message_notify_on_insert on public.messages;
--
-- notify_message() is not touched by this file, so there is nothing else to
-- undo.
-- ───────────────────────────────────────────────────────────────────────────
