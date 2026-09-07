-- reach_events: acknowledged_at is the only column a client may UPDATE.
--
-- 20260601000400 gave reach_events an UPDATE policy scoped to the couple and
-- never narrowed the table-level UPDATE grant Supabase hands `authenticated`
-- by default (20260601007010 removed only truncate/references/trigger). So a
-- signed-in member could PATCH any column of any row in the couple:
--   * created_at backwards - which is what send_next_allowed_at reads
--     (20260819110000), so the 30s / 5-per-5-min Reach cooldown could be
--     cleared by the very client it throttles;
--   * from_user - re-attributing a Reach to the partner.
-- The sibling table got this right in June (20260601002250:69-70); this is
-- the same two statements. The only UPDATE any shipped build issues on this
-- table is acknowledged_at (reach_repository.dart), so build 73 keeps working
-- unchanged.
--
-- Additive: no column, policy, trigger or index changes. Re-runnable: revoke
-- and grant are idempotent; the assertions pass again.
--
-- ROLLBACK (paste first if needed; anon never had a legitimate UPDATE and is
-- not restored):
--   grant update on public.reach_events to authenticated;
--   revoke update (acknowledged_at) on public.reach_events from authenticated;
revoke update on public.reach_events from authenticated, anon;
grant update (acknowledged_at) on public.reach_events to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'reach_events'
      and policyname = 'reach_update'
  ) then
    raise exception 'reach_update policy is missing; the ack would have no policy to pass';
  end if;
  if not has_column_privilege('authenticated', 'public.reach_events',
                              'acknowledged_at', 'UPDATE') then
    raise exception 'authenticated lost UPDATE on reach_events.acknowledged_at';
  end if;
  if has_column_privilege('authenticated', 'public.reach_events',
                          'created_at', 'UPDATE') then
    raise exception 'authenticated can still UPDATE reach_events.created_at';
  end if;
  if has_column_privilege('authenticated', 'public.reach_events',
                          'from_user', 'UPDATE') then
    raise exception 'authenticated can still UPDATE reach_events.from_user';
  end if;
end $$;
