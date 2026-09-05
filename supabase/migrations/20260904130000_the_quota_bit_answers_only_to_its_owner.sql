-- Security audit 2026-09-04. storage_quota_ok answers about whoever is named,
-- not about whoever is asking.
--
-- 20260817160000 closed this function to anon and deliberately KEPT execute
-- for authenticated, because storage_quota_limit — a RESTRICTIVE INSERT policy
-- on storage.objects, `with check ((owner is null) or storage_quota_ok(owner))`
-- — calls it, and a policy expression is evaluated with the privileges of the
-- role running the statement. Revoking would fail every upload. That reasoning
-- was right and still is: the grant stays, and this migration does not touch
-- it.
--
-- What it left open is the argument. The function is SECURITY DEFINER and
-- takes a uuid, so any signed-in user can POST /rest/v1/rpc/storage_quota_ok
-- naming somebody else's id and read a bit back about a stranger's storage
-- usage. One bit is not much. It is still an answer about an account the
-- caller has nothing to do with, and it is the last place in the schema where
-- a client-supplied id reaches a SECURITY DEFINER body with no membership
-- check — the same class of defect 20260829145343 went through the schema to
-- close.
--
-- The bit now comes back only to the owner it is about:
--
--   * auth.uid() is null for the cron reconciler (job 14 runs as postgres) and
--     for service_role, so both evaluate exactly as before.
--   * Inside the policy the caller IS the owner — storage sets objects.owner
--     to auth.uid() on insert — so no upload changes behaviour.
--   * A mismatched pair returns null, not false. Null is not true, so the
--     RESTRICTIVE check still denies; and a prober learns nothing about the id
--     it named, because null comes back whatever that account's usage is.
--
-- Re-runnable: create or replace only. No ACL change, no policy change.
--
-- Reverse with:
--   create or replace function public.storage_quota_ok(p_owner uuid)
--   returns boolean language sql stable security definer set search_path = public
--   as $fn$
--     select coalesce((select bytes from public.storage_usage where user_id = p_owner), 0)
--            < public.storage_quota_bytes();
--   $fn$;

create or replace function public.storage_quota_ok(p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select case
    when auth.uid() is null or p_owner = auth.uid() then
      coalesce(
        (select bytes from public.storage_usage where user_id = p_owner), 0
      ) < public.storage_quota_bytes()
    else null
  end;
$fn$;

-- Assertion: the grant 20260817160000 argued for is still there. Without it
-- storage_quota_limit cannot evaluate and every upload fails closed, which is
-- the one way this migration could do harm.
do $$
begin
  if not has_function_privilege(
       'authenticated', 'public.storage_quota_ok(uuid)', 'EXECUTE')
  then
    raise exception
      'storage_quota_limit calls storage_quota_ok(uuid) in its WITH CHECK; '
      'authenticated must keep EXECUTE or every upload fails';
  end if;
end $$;
