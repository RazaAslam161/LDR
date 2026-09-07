-- The quota answers its owner.
--
-- 20260817140000 keeps a per-user byte counter (storage_usage) and refuses an
-- over-quota upload with a RESTRICTIVE INSERT policy, and nothing in the app
-- has ever read the counter: a refused upload is a generic 403 that the
-- client words as "check your connection", and Settings has no idea how full
-- the account is. One self-scoped read closes both: the number for Settings,
-- and the honest sentence after a 403 (bytes >= quota -> "storage is full",
-- anything else -> the generic copy, because a quota refusal and any other
-- RLS refusal are byte-identical on the wire).
--
-- No new policy. The plan proposed a RESTRICTIVE UPDATE twin "for the upsert
-- bypass"; PostgreSQL's CREATE POLICY documents that an INSERT ... ON
-- CONFLICT DO UPDATE checks the INSERT policies' WITH CHECK expressions for
-- ALL rows proposed for insertion, whether or not they end up being inserted,
-- so storage_quota_limit already binds every upsert on every bucket. There is
-- no bypass to close.
--
-- Additive: one new function. Re-runnable: create or replace; grants are
-- idempotent; the assertions pass again. storage_quota_ok / storage_quota_bytes
-- / reconcile_storage_usage are untouched (20260904130000 pins their ACL).
--
-- ROLLBACK (paste first if needed):
--   drop function if exists public.my_storage_usage();

-- Applied via the Supabase MCP (staging 2026-09-06, production 2026-09-06); production ledger version 20260906121601
-- (apply_migration stamps its own version - the repo prefix is the replay order).

create or replace function public.my_storage_usage()
returns jsonb language sql stable security definer
set search_path = public as $fn$
  select jsonb_build_object(
    'bytes', coalesce((select u.bytes from public.storage_usage u
                        where u.user_id = auth.uid()), 0),
    'quota', public.storage_quota_bytes()
  );
$fn$;

revoke all on function public.my_storage_usage() from public, anon;
grant execute on function public.my_storage_usage() to authenticated;

do $do$
begin
  if not has_function_privilege('authenticated', 'public.my_storage_usage()', 'EXECUTE') then
    raise exception 'authenticated cannot execute my_storage_usage()';
  end if;
  if has_function_privilege('anon', 'public.my_storage_usage()', 'EXECUTE') then
    raise exception 'anon can execute my_storage_usage()';
  end if;
  if not has_function_privilege('authenticated', 'public.storage_quota_ok(uuid)', 'EXECUTE') then
    raise exception 'storage_quota_ok lost EXECUTE for authenticated; every upload would fail closed';
  end if;
end $do$;
