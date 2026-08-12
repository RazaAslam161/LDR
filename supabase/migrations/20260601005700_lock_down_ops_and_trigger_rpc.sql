-- ───────────────────────────────────────────────────────────────────────────
-- Two grants that were wider than anything needed them to be.
--
-- 1. ops_job_runs was created an hour earlier with RLS on and no policies,
--    which is deny-all and was the intent — but Supabase's default privileges
--    had already handed anon and authenticated `arwdDxtm` on it. RLS was the
--    only thing standing between an anonymous caller and full write. One
--    layer is not a posture: a future `disable row level security`, typed
--    while debugging something else, would silently open it. Take the grant
--    away too, so RLS is the second line rather than the only one.
--
-- 2. clear_dissolved_on_join() is a TRIGGER function, and triggers run as the
--    table owner no matter who holds EXECUTE. The grant bought nothing and
--    published it at /rest/v1/rpc/clear_dissolved_on_join for anon — the only
--    one of the project's SECURITY DEFINER functions reachable without signing
--    in. Calling it that way fails for want of a trigger context, so this is
--    surface rather than a hole, but surface is what gets probed.
-- ───────────────────────────────────────────────────────────────────────────

revoke all on public.ops_job_runs from public, anon, authenticated;

revoke execute on function public.clear_dissolved_on_join() from public, anon, authenticated;
