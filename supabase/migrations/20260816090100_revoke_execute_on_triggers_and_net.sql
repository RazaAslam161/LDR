-- ───────────────────────────────────────────────────────────────────────────
-- Miles — EXECUTE that nobody needed, on functions no client can call.
--
-- Postgres grants EXECUTE to PUBLIC on every new function, and Supabase's
-- default privileges in this schema add anon and authenticated on top, so
-- every trigger function in public carried three grants for a call that cannot
-- happen: Postgres refuses to run these through /rest/v1/rpc/ at all —
-- "trigger functions can only be called as triggers". It was never a live
-- hole. It is removed because the alternative is leaving a standing grant that
-- only stays harmless while that refusal holds.
--
-- lock_down_ops_and_trigger_rpc already did this for the functions that
-- existed when it was written; eight more have landed since (the memory and
-- gallery triggers), which is the tell — naming functions one at a time loses
-- to a codebase that keeps adding them. This revokes by SHAPE, anything
-- returning trigger or event_trigger, so the next one is covered on the day it
-- is created rather than the day somebody notices.
--
-- Safe: Postgres checks EXECUTE on a trigger function when the trigger is
-- CREATED, never when it fires. Every existing trigger goes on running.
--
-- ── What is deliberately NOT here: pg_net ──────────────────────────────────
--
-- net.http_post and net.http_get are executable by anon and authenticated, and
-- schema net carries USAGE for both. That is a real outbound-HTTP primitive
-- sitting behind a role a stranger can hold, and the first version of this
-- migration tried to revoke it.
--
-- It cannot be revoked from here, and the attempt was worse than useless: the
-- grants read `=X/supabase_admin`, a privilege may only be revoked by the role
-- that granted it, and this database's owner is not that role —
-- pg_has_role(postgres, supabase_admin) is false and postgres is not a
-- superuser. The REVOKE therefore succeeded, changed nothing, and left a line
-- in this file claiming a protection that did not exist. A guard that can
-- silently no-op is not a guard.
--
-- What actually holds it shut is that PostgREST exposes only the public schema,
-- so no client request resolves a name in net. That is a setting this repo does
-- not own, which is exactly why it is written down here: if db_schemas ever
-- grows, this becomes reachable the same day. Closing it properly needs
-- Supabase support or a superuser, and it is tracked, not fixed.
--
-- Rollback (restores the default PUBLIC + Supabase default grants):
--   do $$ declare f record; begin
--     for f in select p.oid::regprocedure sig from pg_proc p
--       join pg_namespace n on n.oid=p.pronamespace
--       join pg_type t on t.oid=p.prorettype
--      where n.nspname='public' and p.prokind='f'
--        and t.typname in ('trigger','event_trigger')
--     loop execute format(
--       'grant execute on function %s to public, anon, authenticated', f.sig);
--     end loop;
--   end $$;
--
-- Re-running is a no-op: revoking a privilege already absent is not an error.

do $do$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join pg_type t on t.oid = p.prorettype
     where n.nspname = 'public'
       and p.prokind = 'f'
       and t.typname in ('trigger', 'event_trigger')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $do$;
