-- ───────────────────────────────────────────────────────────────────────────
-- Miles — anon could write, on paper.
--
-- The anon role held INSERT, UPDATE and DELETE across 125 table/verb pairs.
-- RLS denied it twice over — no policy names anon, and current_user_couple_id()
-- is not even executable by it — so this was never a live hole. It was the
-- layer underneath both of those, kept for no reason: the app has no anonymous
-- write path at all, every screen sits behind sign-in.
--
-- Leaving it is a bet that two other layers never regress. Removing it costs
-- nothing, because nothing used it. Verified after: 0 anon writes, and
-- authenticated still reads 42 tables and writes 43.
--
-- SELECT is deliberately left alone. anon still cannot read anything — RLS sees
-- to that — and revoking it would change the failure a misconfigured client
-- gets from an empty result to a hard permission error, which is harder to
-- diagnose, not safer.
do $do$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('revoke insert, update, delete on public.%I from anon', t.tablename);
  end loop;
end $do$;
