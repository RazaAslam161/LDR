-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the album is open for thirty days, not forever.
--
-- OWNER'S RULING (2026-09-09, narrowing the one three hours earlier): the
-- gallery "is a mutual shared place", so it should not outlive the couple
-- indefinitely. The vault should — and always did. What both people get
-- instead is a WINDOW: for thirty days after an unlink the album stays open,
-- read-only, and either of them can save whatever they want out of it into
-- their own private vault, which nothing about a couple can ever touch. After
-- that the shared place goes, exactly as the published privacy policy has said
-- all along.
--
-- ONE NUMBER, TWO DOORS. dissolution_window() (20260826160000) exists so a
-- deadline cannot be written twice and drift. It now governs three things that
-- close on the same instant: the restore handshake, this album, and
-- prune_dissolved_couples(). archived_couple_id() admits the couple while
-- `dissolved_at > now() - window`; the pruner collects it once
-- `dissolved_at < now() - window`. No gap either side, and no second literal.
--
-- WHAT THIS FIXES, BEYOND THE RULING. 20260909170000 protected the whole
-- `couples` row from the pruner, and 45 foreign keys cascade from it, so
-- messages and Closer content became permanent as a side effect — the exact
-- outcome 20260601005100 was written to prevent. Removing the guard puts them
-- back on the thirty-day clock. That was the open item at the end of §316 and
-- it closes here rather than being carried.
--
-- released_at STAYS, and is not made redundant by the window. Without it:
-- unlink from A on day 1, pair with B on day 5, unlink from B on day 10 — and
-- A's album, still inside ITS own thirty days, comes back. The owner's rule is
-- that linking with somebody new ends it, and ends it for good. Both
-- conditions hold: whichever comes first.
--
-- ── ROLLBACK (the state 20260909170000 left, captured before this ran) ──────
--   create or replace function public.archived_couple_id()
--   returns uuid language sql stable security definer set search_path = public as $r$
--     select cm.couple_id
--       from public.couple_members cm
--       join public.couples c on c.id = cm.couple_id
--      where cm.user_id = (select auth.uid())
--        and cm.severed_at is null
--        and cm.released_at is null
--        and c.dissolved_at is not null
--        and (select p.couple_id from public.profiles p
--              where p.id = (select auth.uid())) is null
--      order by c.dissolved_at desc
--      limit 1
--   $r$;
--   create or replace function public.prune_dissolved_couples()
--   returns void language plpgsql security definer set search_path = public as $r$
--   declare v_id uuid;
--   begin
--     for v_id in
--       select id from public.couples
--        where dissolved_at is not null
--          and dissolved_at < now() - public.dissolution_window()
--          and not exists (select 1 from public.profiles p where p.couple_id = couples.id)
--          and not exists (select 1 from public.couple_members cm
--                           where cm.couple_id = couples.id
--                             and cm.severed_at is null
--                             and cm.released_at is null)
--     loop
--       perform public.purge_couple(v_id);
--     end loop;
--   end $r$;
--   drop function if exists public.archived_gallery();
--
-- A SECOND APPLY IS A NO-OP: three create-or-replaces and nothing else.
-- ───────────────────────────────────────────────────────────────────────────

-- ── The album closes with the window ──────────────────────────────────────
create or replace function public.archived_couple_id()
returns uuid language sql stable security definer set search_path = public as $fn$
  select cm.couple_id
    from public.couple_members cm
    join public.couples c on c.id = cm.couple_id
   where cm.user_id = (select auth.uid())
     and cm.severed_at is null
     and cm.released_at is null
     and c.dissolved_at is not null
     and c.dissolved_at > now() - public.dissolution_window()
     and (select p.couple_id from public.profiles p
           where p.id = (select auth.uid())) is null
   order by c.dissolved_at desc
   limit 1
$fn$;

revoke execute on function public.archived_couple_id() from public, anon;
grant  execute on function public.archived_couple_id() to authenticated;

-- ── The deadline, so the screen can say it ────────────────────────────────
-- An album that closes silently is precisely the harm this ruling exists to
-- avoid: somebody who is not told loses the photographs they meant to keep.
-- The grid needs a date, and the uuid above cannot carry one.
--
-- Wraps archived_couple_id() rather than restating its five conditions —
-- exactly how couple_restore_state() wraps current_user_restorable_couple_id()
-- (20260826160000), and for the same reason: one predicate, one place to be
-- wrong. Returns a single uniform NULL for every negative case, so nothing a
-- caller can do reveals which one it was.
create or replace function public.archived_gallery()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare v_couple uuid; v_dissolved timestamptz;
begin
  v_couple := public.archived_couple_id();
  if v_couple is null then return null; end if;
  select dissolved_at into v_dissolved from public.couples where id = v_couple;
  if v_dissolved is null then return null; end if;
  return jsonb_build_object(
    'couple_id',  v_couple,
    'expires_at', v_dissolved + public.dissolution_window()
  );
end $fn$;

revoke execute on function public.archived_gallery() from public, anon;
grant  execute on function public.archived_gallery() to authenticated;

-- ── The pruner goes back to collecting at thirty days ─────────────────────
-- Byte-for-byte the definition that stood before 20260909170000, captured live
-- with pg_get_functiondef. The couple_members guard is gone: with the album on
-- a clock there is nothing left for it to protect, and leaving it in is what
-- made the couple's messages permanent.
create or replace function public.prune_dissolved_couples()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_id uuid;
begin
  for v_id in
    select id from public.couples
     where dissolved_at is not null
       and dissolved_at < now() - public.dissolution_window()
       and not exists (select 1 from public.profiles p where p.couple_id = couples.id)
  loop
    perform public.purge_couple(v_id);
  end loop;
end $fn$;

revoke execute on function public.prune_dissolved_couples() from public, anon, authenticated;
