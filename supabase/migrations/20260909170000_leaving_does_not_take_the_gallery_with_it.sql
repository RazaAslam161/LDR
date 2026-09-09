-- ───────────────────────────────────────────────────────────────────────────
-- Miles — leaving does not take the gallery with it.
--
-- THE RULE (owner, 2026-09-09): "after un-linking with the partner, user should
-- have access of it's account, like vault and gallery, it should not gone. it
-- should be only gone when linked with other partner." Rulings on the three
-- open questions, same day: the WHOLE shared album stays readable to BOTH
-- ex-partners; "erase" stays MUTUAL (leave_couple_permanently is still the only
-- erase, and it still binds the couple, not the person); scope is vault +
-- gallery only.
--
-- WHAT WAS ACTUALLY WRONG. The vault was never in danger: personal_vault_items
-- is owner_id-keyed, the personal_vault bucket compares its first folder to
-- auth.uid(), purge_couple() names four buckets and deliberately excludes it,
-- and its key is derived from the account's own seed. What removed it was the
-- CLIENT — router.dart sends an unpaired account to /couple from every route.
-- The gallery is the real loss: gallery_items and couple_intimate both resolve
-- through current_user_couple_id(), which is `select couple_id from profiles
-- where id = auth.uid()`, and dissolve_couple() nulls it on both sides. 431
-- rows and ~1.1 GB go dark at the instant of unlink, and prune-dissolved-
-- couples deletes them thirty days later.
--
-- NOTHING IS COPIED. The obvious shape — hand each ex their own copy — is
-- blocked three ways: storage.protect_delete raises 42501 on a direct delete of
-- storage.objects so every move needs the Storage API; the per-user 5 GiB quota
-- is an RLS INSERT policy (storage_quota_ok) and the heavier live account is
-- already ~1.2 GB, so duplicating the album can fail as a policy denial rather
-- than an error the app authors; and _gallery_reap queues BOTH storage_path and
-- thumb_path on any deleted false->true, so "copy then soft-delete" destroys
-- the bytes both copies name. The objects stay exactly where they are at
-- <couple_id>/gallery/… and only the SELECT predicate widens.
--
-- LAWS this file is built on:
--  * ADDITIVE ONLY. gallery_select_member and closer_intimate_media_read are
--    not touched. Permissive policies OR together, so build 83 — which never
--    queries a couple it is not in — cannot tell this migration happened.
--  * READS WIDEN, WRITES DO NOT. Every insert/update/delete path still resolves
--    current_user_couple_id(). The archive is therefore read-only BY
--    CONSTRUCTION: there is no new refusal to write, and no new way to be wrong.
--  * AT MOST ONE ARCHIVE. A person is in one couple at a time and joining any
--    couple releases every other, so archived_couple_id() can return a single
--    uuid. It mirrors current_user_restorable_couple_id() line for line,
--    including the final clause — the caller currently has no couple — which is
--    the owner's "gone when linked with other partner", already expressed.
--  * released_at IS LOAD-BEARING, not decoration. That final clause alone says
--    "hidden while paired". Probed live before this file was written: for the
--    one real account that has left one couple and joined another, the
--    predicate WITHOUT released_at resolves the old couple the moment they
--    unlink from the new one. released_at makes leaving-for-someone-else
--    permanent, which is what was asked for.
--  * THE PRUNER IS HALF THE REQUIREMENT. Without the couple_members guard below
--    this migration works on day 1 and fails silently at 05:07 on day 30.
--
-- NOT IN THIS FILE, ON PURPOSE: the 30-day dissolution_window() still governs
-- the RESTORE handshake (restore_couple, couple_restore_state, the rewrap
-- policies). Reading an archive and rebuilding a couple are different powers
-- and keep different clocks.
--
-- ── ROLLBACK (write it before you apply it) ────────────────────────────────
--   drop policy if exists gallery_select_archived on public.gallery_items;
--   drop policy if exists couple_intimate_read_archived on storage.objects;
--   -- pre-migration body, captured live 2026-09-09 with pg_get_functiondef:
--   create or replace function public.prune_dissolved_couples()
--   returns void language plpgsql security definer set search_path = public as $r$
--   declare v_id uuid;
--   begin
--     for v_id in
--       select id from public.couples
--        where dissolved_at is not null
--          and dissolved_at < now() - public.dissolution_window()
--          and not exists (select 1 from public.profiles p where p.couple_id = couples.id)
--     loop
--       perform public.purge_couple(v_id);
--     end loop;
--   end $r$;
--   create or replace function public.sync_couple_members()
--   returns trigger language plpgsql security definer set search_path = public as $r$
--   begin
--     if tg_op = 'UPDATE' then
--       if old.couple_id is not null
--          and old.couple_id is distinct from new.couple_id then
--         update public.couple_members set left_at = now()
--          where couple_id = old.couple_id and user_id = new.id and left_at is null;
--       end if;
--     end if;
--     if new.couple_id is not null then
--       if tg_op = 'INSERT' then
--         insert into public.couple_members (couple_id, user_id)
--         values (new.couple_id, new.id)
--         on conflict (couple_id, user_id) do update set left_at = null;
--       elsif new.couple_id is distinct from old.couple_id then
--         insert into public.couple_members (couple_id, user_id)
--         values (new.couple_id, new.id)
--         on conflict (couple_id, user_id) do update set left_at = null;
--       end if;
--     end if;
--     return new;
--   end $r$;
--   drop function if exists public.archived_couple_id();
--   alter table public.couple_members drop column if exists released_at;
--
-- A SECOND APPLY IS A NO-OP: every statement is add-if-not-exists, create-or-
-- replace, or drop-policy-then-create, and the backfill's own `released_at is
-- null` guard means it touches nothing the second time.
-- ───────────────────────────────────────────────────────────────────────────

-- ── The column that makes leaving-for-someone-else permanent ───────────────
-- couple_members already carries left_at (you unlinked) and severed_at (the
-- couple was ended permanently, by either of you). Neither says "this person
-- has moved on", which is the only thing that ends the archive.
alter table public.couple_members
  add column if not exists released_at timestamptz;

-- ── The trigger learns one more sentence ──────────────────────────────────
-- Body below is the LIVE definition captured with pg_get_functiondef on
-- 2026-09-09, plus the release. The TG_OP tests stay NESTED for the reason the
-- original states: PL/pgSQL does not promise to short-circuit a boolean and
-- `old.couple_id` raises under TG_OP='INSERT'. v_joined exists so the release
-- is written once instead of copied into both branches, and so it cannot fire
-- on an UPDATE that rewrote couple_id to the value it already had.
--
-- `couple_id <> new.couple_id` is what protects reconciliation: getting back
-- together with the SAME person re-enters that couple, so its own membership is
-- excluded from the release and clear_dissolved_on_join lifts it back to live.
create or replace function public.sync_couple_members()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare v_joined boolean := false;
begin
  if tg_op = 'UPDATE' then
    if old.couple_id is not null
       and old.couple_id is distinct from new.couple_id then
      update public.couple_members
         set left_at = now()
       where couple_id = old.couple_id
         and user_id = new.id
         and left_at is null;
    end if;
  end if;

  if new.couple_id is not null then
    if tg_op = 'INSERT' then
      insert into public.couple_members (couple_id, user_id)
      values (new.couple_id, new.id)
      on conflict (couple_id, user_id) do update set left_at = null;
      v_joined := true;
    elsif new.couple_id is distinct from old.couple_id then
      insert into public.couple_members (couple_id, user_id)
      values (new.couple_id, new.id)
      on conflict (couple_id, user_id) do update set left_at = null;
      v_joined := true;
    end if;

    if v_joined then
      update public.couple_members
         set released_at = now()
       where user_id = new.id
         and couple_id <> new.couple_id
         and released_at is null;
    end if;
  end if;

  return new;
end $fn$;

revoke execute on function public.sync_couple_members() from public, anon, authenticated;

-- ── The one predicate every archive read routes through ───────────────────
-- Deliberately the same shape as current_user_restorable_couple_id(): one
-- function a reviewer has to read, returning NULL for every negative case —
-- never a member, moved on, severed, couple already purged, or currently
-- paired. NULL is what makes both policies below fail closed, because
-- `couple_id = NULL` is NULL and never true.
--
-- No dissolution_window() here, and that is the whole change in kind: the
-- archive has no clock. It ends when the person ends it, by pairing again or by
-- the permanent exit.
create or replace function public.archived_couple_id()
returns uuid language sql stable security definer set search_path = public as $fn$
  select cm.couple_id
    from public.couple_members cm
    join public.couples c on c.id = cm.couple_id
   where cm.user_id = (select auth.uid())
     and cm.severed_at is null
     and cm.released_at is null
     and c.dissolved_at is not null
     and (select p.couple_id from public.profiles p
           where p.id = (select auth.uid())) is null
   order by c.dissolved_at desc
   limit 1
$fn$;

revoke execute on function public.archived_couple_id() from public, anon;
grant  execute on function public.archived_couple_id() to authenticated;

-- ── The two reads that widen ──────────────────────────────────────────────
-- ADDITIONAL policies. gallery_select_member (20260601008000) and
-- closer_intimate_media_read (20260601006300) are untouched and still carry the
-- live couple; PostgreSQL ORs permissive policies, so a paired account's reads
-- resolve exactly as they did.
--
-- The `(select …)` wrapper is not style: it makes the planner evaluate the
-- predicate once as an InitPlan instead of once per row, which is why the
-- existing policies are written that way over 431 rows.
drop policy if exists gallery_select_archived on public.gallery_items;
create policy gallery_select_archived on public.gallery_items
  for select using (couple_id = (select public.archived_couple_id()));

-- The bytes, on the same terms. SELECT only: insert, update and delete on
-- couple_intimate keep resolving current_user_couple_id(), so nothing can be
-- added to or removed from an archive.
drop policy if exists couple_intimate_read_archived on storage.objects;
create policy couple_intimate_read_archived on storage.objects
  for select to authenticated
  using (
    bucket_id = 'couple_intimate'
    and (storage.foldername(name))[1] = (select public.archived_couple_id())::text
  );

-- ── The pruner stops deleting what somebody still holds ───────────────────
-- Body is the LIVE definition captured 2026-09-09, with one guard added. The
-- existing `not exists … profiles` test is not enough on its own: after a
-- breakup NOBODY points at the couple, which is exactly the state the archive
-- lives in.
--
-- What still gets collected, unchanged: a couple both people have moved on from
-- (both released), a couple either of them ended permanently (severed, and
-- leave_couple_permanently purges inline anyway), and every couple dissolved
-- before this migration whose members have since re-paired — the backfill below
-- is what puts those back on the clock rather than protecting them forever.
create or replace function public.prune_dissolved_couples()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_id uuid;
begin
  for v_id in
    select id from public.couples
     where dissolved_at is not null
       and dissolved_at < now() - public.dissolution_window()
       and not exists (select 1 from public.profiles p where p.couple_id = couples.id)
       and not exists (select 1 from public.couple_members cm
                        where cm.couple_id = couples.id
                          and cm.severed_at is null
                          and cm.released_at is null)
  loop
    perform public.purge_couple(v_id);
  end loop;
end $fn$;

revoke execute on function public.prune_dissolved_couples() from public, anon, authenticated;

-- ── History, reconstructed rather than assumed ────────────────────────────
-- Memberships that ended before this column existed carry released_at = NULL,
-- which would hand an archive to somebody who has already moved on — and worse,
-- would protect their old couple from the pruner permanently. Anyone who left a
-- couple and later joined a DIFFERENT one is released as of the day they
-- joined it.
--
-- Rows touched is raised rather than assumed: on production this is expected to
-- be exactly 1 (couple 5df6a383, user 6076edae, who left on 2026-09-02 and
-- joined 29b68a18 thirteen minutes later). A different number means the history
-- is not what this file thinks it is.
do $do$
declare v_n integer;
begin
  update public.couple_members cm
     set released_at = later.joined_at
    from public.couple_members later
   where later.user_id  = cm.user_id
     and later.couple_id <> cm.couple_id
     and cm.left_at is not null
     and later.joined_at >= cm.left_at
     and cm.released_at is null;
  get diagnostics v_n = row_count;
  raise notice 'released_at backfill: % row(s) released', v_n;
end $do$;
