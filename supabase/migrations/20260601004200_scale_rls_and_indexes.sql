-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the two things that decide whether this survives thousands of users.
--
-- Found by the performance advisor: 38 policies re-evaluating auth on every
-- row, and 41 foreign keys with no index. Both are invisible with two users and
-- both are the first thing to hurt with two thousand.
-- ───────────────────────────────────────────────────────────────────────────

-- 1. RLS InitPlan hoisting.
--
-- A policy written `couple_id = current_user_couple_id()` calls that function
-- ONCE PER ROW EXAMINED. Wrapped in a scalar subquery, Postgres lifts it into
-- an InitPlan and calls it once per QUERY. Identical semantics — the difference
-- is whether scanning 5,000 messages makes 5,000 SECURITY DEFINER calls, each
-- of which itself queries profiles, or one.
--
-- Written as a catalogue loop, not a list of 134 ALTERs, so it covers policies
-- added later and cannot miss one by hand. Idempotent: an already-hoisted
-- policy is skipped rather than wrapped twice.
do $do$
declare r record; q text; w text; stmt text; n int := 0;
begin
  for r in
    select c.relname as tbl, p.polname as pol,
           pg_get_expr(p.polqual, p.polrelid) as qual,
           pg_get_expr(p.polwithcheck, p.polrelid) as chk
    from pg_policy p
    join pg_class c on c.oid = p.polrelid
    join pg_namespace ns on ns.oid = c.relnamespace and ns.nspname = 'public'
  loop
    q := r.qual;
    w := r.chk;

    if coalesce(q,'') ilike '%select auth.uid()%'
       or coalesce(q,'') ilike '%select current_user_couple_id()%'
       or coalesce(w,'') ilike '%select auth.uid()%'
       or coalesce(w,'') ilike '%select current_user_couple_id()%' then
      continue;
    end if;

    if q is not null then
      q := replace(q, 'auth.uid()', '(select auth.uid())');
      q := replace(q, 'current_user_couple_id()', '(select current_user_couple_id())');
    end if;
    if w is not null then
      w := replace(w, 'auth.uid()', '(select auth.uid())');
      w := replace(w, 'current_user_couple_id()', '(select current_user_couple_id())');
    end if;

    if q is not null and w is not null then
      stmt := format('alter policy %I on public.%I using (%s) with check (%s)', r.pol, r.tbl, q, w);
    elsif q is not null then
      stmt := format('alter policy %I on public.%I using (%s)', r.pol, r.tbl, q);
    elsif w is not null then
      stmt := format('alter policy %I on public.%I with check (%s)', r.pol, r.tbl, w);
    else
      continue;
    end if;

    execute stmt;
    n := n + 1;
  end loop;
  raise notice 'hoisted % policies', n;
end $do$;

-- 2. Index every foreign key.
--
-- An unindexed FK makes the CHILD side of a cascade a sequential scan.
-- delete_my_account() cascades from auth.users through profiles and couples
-- across dozens of tables; unindexed, deleting one account walks every row of
-- each one. Ordinary joins pay the same cost on every read.
--
-- Also generated from the catalogue, for the same reason.
do $do$
declare r record; idx text;
begin
  for r in
    select t.relname as tbl,
           (select string_agg(quote_ident(a.attname), ', ' order by k.ord)
              from unnest(c.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
           ) as collist
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace and n.nspname = 'public'
    where c.contype = 'f'
      and not exists (
        select 1 from pg_index i
        where i.indrelid = c.conrelid
          and (i.indkey::int2[])[0:array_length(c.conkey,1)-1] = c.conkey
      )
  loop
    idx := left('idx_' || r.tbl || '_' || replace(r.collist, ', ', '_'), 63);
    execute format('create index if not exists %I on public.%I (%s)', idx, r.tbl, r.collist);
  end loop;
end $do$;

analyze;

-- ── Left alone deliberately ─────────────────────────────────────────────────
--
-- The advisor reports these 42 new indexes as "unused". They are: nothing has
-- queried them since they were created seconds ago. Dropping them is the exact
-- mistake the warning invites.
--
-- cycle_events, cycle_logs and cycle_settings each keep TWO permissive policies
-- and will keep being flagged for it. They are not duplicates: one grants the
-- owner everything, the other lets the partner read when sharing is on. OR-ing
-- them is the feature. Merging them would either leak or break sharing.
-- ───────────────────────────────────────────────────────────────────────────
