-- ───────────────────────────────────────────────────────────────────────────
-- Miles — restore needs both of them.
--
-- The last stage. 20260826160000 made a dissolved couple addressable,
-- 20260826170000 gave either ex-member a way to end it permanently, and
-- 20260826180000 made sure a reinstall inside the window does not leave the
-- history unreadable. This is the way back.
--
-- THE OWNER'S RULING, AND THE WHOLE SHAPE OF IT: reunion needs BOTH, always.
-- One asks, the other confirms, nobody confirms their own request. In the
-- situation this was built for — one partner removes the other in anger and
-- regrets it — the other person wants it back too, so consent is cheap. In the
-- situation THREAT-MODEL.md §3 is about, it is the entire protection: somebody
-- who takes an unlocked phone finds nothing here that restores their access.
--
-- THERE IS DELIBERATELY NO FORCE COUNTERPART. memory_force_delete lets one
-- person act alone after 14 days, and for a single memory row that is
-- reasonable. For the relationship itself a unilateral escape is not an escape
-- hatch, it is a mechanism to force restoration on somebody who declined. If a
-- future change adds one, the assertion at the bottom of this file fails.
--
-- A DECLINE IS FINAL FOR THE PERSON WHO WAS DECLINED. Without that, one open
-- request per couple is not a limit — it is a rate. Ask, get declined, ask
-- again is a notification channel pointed at somebody who left. The other
-- person may still make their OWN request later, because changing your mind
-- about your own decision is not badgering.
--
-- ONLY 'reunite' IS REACHABLE THIS ROUND. The `kind` column accepts 'archive'
-- so the later read-only-archive round is additive rather than a retype, but
-- the RPC refuses it: the read half does not exist yet, and shipping the
-- request half early would put a control on screen that cannot do anything.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.couple_restore_requests (
  -- PK on couple_id gives "one open request per couple" for free.
  couple_id          uuid primary key references public.couples(id) on delete cascade,
  kind               text not null check (kind in ('reunite','archive')),
  requested_by       uuid not null references public.profiles(id) on delete cascade,
  requested_at       timestamptz not null default now(),
  confirmed_by       uuid references public.profiles(id) on delete set null,
  confirmed_at       timestamptz,
  declined_by        uuid references public.profiles(id) on delete set null,
  declined_at        timestamptz,
  restored_at        timestamptz,
  -- Written only by the deferred archive round; nothing reads it yet.
  archive_expires_at timestamptz
);

alter table public.couple_restore_requests enable row level security;

-- RPC-only, the memory_threads posture. No DML grant means a PostgREST PATCH
-- cannot confirm a request on your behalf, which is the one write that must
-- never be reachable except through a function that checks who is asking.
revoke all on public.couple_restore_requests from anon, authenticated;
grant select on public.couple_restore_requests to authenticated;

drop policy if exists couple_restore_visible on public.couple_restore_requests;
create policy couple_restore_visible on public.couple_restore_requests
  for select using (
    couple_id = (select public.current_user_restorable_couple_id()));

-- ── Ask ────────────────────────────────────────────────────────────────────
create or replace function public.couple_restore_request(p_kind text default 'reunite')
returns void language plpgsql security definer set search_path = public as $fn$
declare v_couple uuid; v_row public.couple_restore_requests;
begin
  if p_kind is distinct from 'reunite' then
    raise exception 'archive_not_available';
  end if;

  v_couple := public.current_user_restorable_couple_id();
  if v_couple is null then raise exception 'no_restorable_couple'; end if;

  select * into v_row from public.couple_restore_requests where couple_id = v_couple;

  if found then
    if v_row.declined_at is not null then
      -- Declined. Final for whoever was turned down; the other may still ask
      -- once themselves.
      if v_row.requested_by = auth.uid() then
        raise exception 'declined';
      end if;
      delete from public.couple_restore_requests where couple_id = v_couple;
    elsif v_row.restored_at is null then
      raise exception 'already_requested';
    else
      delete from public.couple_restore_requests where couple_id = v_couple;
    end if;
  end if;

  insert into public.couple_restore_requests (couple_id, kind, requested_by)
  values (v_couple, 'reunite', auth.uid());
end $fn$;

revoke execute on function public.couple_restore_request(text) from public, anon;
grant  execute on function public.couple_restore_request(text) to authenticated;

-- ── Either of them calls it off ────────────────────────────────────────────
-- Including the person who asked: withdrawing your own request and declining
-- somebody else's are the same verb, and the columns record which it was. The
-- gallery consent RPCs make the same choice for the same reason — changing
-- your mind must not need permission.
create or replace function public.couple_restore_cancel()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_couple uuid;
begin
  v_couple := public.current_user_restorable_couple_id();
  if v_couple is null then raise exception 'no_restorable_couple'; end if;

  update public.couple_restore_requests
     set declined_at = now(), declined_by = auth.uid()
   where couple_id = v_couple
     and declined_at is null
     and restored_at is null;
end $fn$;

revoke execute on function public.couple_restore_cancel() from public, anon;
grant  execute on function public.couple_restore_cancel() to authenticated;

-- ── The other one agrees ───────────────────────────────────────────────────
-- `requested_by is distinct from auth.uid()` is the entire guarantee, and it is
-- the reason this cannot live in the client.
create or replace function public.couple_restore_confirm()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_couple uuid; v_kind text;
begin
  v_couple := public.current_user_restorable_couple_id();
  if v_couple is null then raise exception 'no_restorable_couple'; end if;

  update public.couple_restore_requests
     set confirmed_by = auth.uid(), confirmed_at = now()
   where couple_id = v_couple
     and confirmed_at is null
     and declined_at is null
     and restored_at is null
     and requested_by is distinct from auth.uid()
  returning kind into v_kind;

  if not found then
    raise exception 'only your partner can confirm this';
  end if;

  if v_kind = 'reunite' then
    perform public.restore_couple();
  end if;
end $fn$;

revoke execute on function public.couple_restore_confirm() from public, anon;
grant  execute on function public.couple_restore_confirm() to authenticated;

-- ── The way back ───────────────────────────────────────────────────────────
-- Parameterless on purpose: a couple id parameter would be an identity
-- decision handed to the caller.
create or replace function public.restore_couple()
returns public.couples language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_now uuid; v_couple uuid; v_dissolved timestamptz;
  v_members uuid[]; v_row public.couples;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select couple_id into v_now from public.profiles where id = v_uid;

  -- Idempotency, stated exactly. A second call within five minutes of a
  -- successful restore returns the identical row and mutates nothing — that is
  -- double-tap tolerance and nothing more. Beyond that it raises and still
  -- mutates nothing. The five minutes is arbitrary; it buys only the double tap.
  if v_now is not null then
    if exists (select 1 from public.couple_restore_requests
                where couple_id = v_now
                  and restored_at > now() - interval '5 minutes') then
      select * into v_row from public.couples where id = v_now;
      return v_row;
    end if;
    raise exception 'already_paired';
  end if;

  v_couple := public.current_user_restorable_couple_id();
  if v_couple is null then raise exception 'no_restorable_couple'; end if;

  -- Two phones tapping at the same second is the realistic race, so take the
  -- row and re-check the window INSIDE the lock.
  select dissolved_at into v_dissolved
    from public.couples where id = v_couple for update;
  if v_dissolved is null
     or v_dissolved <= now() - public.dissolution_window() then
    raise exception 'no_restorable_couple';
  end if;

  select coalesce(array_agg(user_id), '{}') into v_members
    from public.couple_members
   where couple_id = v_couple and severed_at is null;
  if coalesce(array_length(v_members, 1), 0) <> 2 then
    raise exception 'no_restorable_couple';
  end if;

  -- BOTH ids, not just the caller's. Restoring a couple whose other half has
  -- started a new relationship would re-pair somebody who has moved on.
  if exists (select 1 from public.profiles
              where id = any (v_members) and couple_id is not null) then
    raise exception 'partner_has_moved_on';
  end if;

  if not exists (select 1 from public.couple_restore_requests
                  where couple_id = v_couple
                    and kind = 'reunite'
                    and confirmed_at is not null
                    and declined_at is null
                    and restored_at is null) then
    raise exception 'consent_required';
  end if;

  -- This fires, in order: guard_couple_id (permits it — SECURITY DEFINER
  -- switches current_user away from 'authenticated', which is the exemption
  -- 20260601003300 documents), trg_sync_presence_couple_id,
  -- profiles_sync_couple_members (clears left_at), trg_init_chat_receipt, and
  -- clear_dissolved_on_join, which sets active = true and dissolved_at = null.
  -- That last trigger has never fired in production: it was written for this in
  -- 20260601005100 and 20260601005900 made it unreachable.
  update public.profiles set couple_id = v_couple where id = any (v_members);

  -- Belt, in case a future change ever detaches that trigger.
  update public.couples
     set active = true, dissolved_at = null
   where id = v_couple;

  update public.couple_restore_requests
     set restored_at = now()
   where couple_id = v_couple;

  -- Presence is deliberately NOT restored. It is live state, not history, and
  -- re-materialising pre-breakup coordinates would be a privacy bug wearing a
  -- feature's clothes. Do not "fix" this later.

  select * into v_row from public.couples where id = v_couple;
  return v_row;
end $fn$;

revoke execute on function public.restore_couple() from public, anon;
grant  execute on function public.restore_couple() to authenticated;

-- ── The read surface learns about the request ──────────────────────────────
-- Still returns NULL — one indistinguishable shape — for every negative case.
-- The request fields are null inside a non-null object when nobody has asked,
-- which tells an ex nothing they could not already infer from being able to
-- call it at all.
create or replace function public.couple_restore_state()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare v_couple uuid; v_dissolved timestamptz; v_req public.couple_restore_requests;
begin
  v_couple := public.current_user_restorable_couple_id();
  if v_couple is null then return null; end if;
  select dissolved_at into v_dissolved from public.couples where id = v_couple;
  if v_dissolved is null then return null; end if;
  select * into v_req from public.couple_restore_requests where couple_id = v_couple;
  return jsonb_build_object(
    'couple_id',      v_couple,
    'dissolved_at',   v_dissolved,
    'expires_at',     v_dissolved + public.dissolution_window(),
    'request_kind',   v_req.kind,
    'request_is_mine',
      case when v_req.requested_by is null then null
           else v_req.requested_by = auth.uid() end,
    'awaiting_me',
      case when v_req.requested_by is null then null
           else (v_req.requested_by is distinct from auth.uid()
                 and v_req.confirmed_at is null
                 and v_req.declined_at is null) end,
    'confirmed',      v_req.confirmed_at is not null,
    'declined',       v_req.declined_at is not null
  );
end $fn$;

revoke execute on function public.couple_restore_state() from public, anon;
grant  execute on function public.couple_restore_state() to authenticated;

-- ── Assertions ─────────────────────────────────────────────────────────────
-- 1. Nobody can confirm their own request.
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='couple_restore_confirm';
  if position('requested_by is distinct from auth.uid()' in v_src) = 0 then
    raise exception
      'couple_restore_confirm no longer requires the OTHER person — one side '
      'can now restore the couple alone, which is exactly what the safety exit '
      'exists to prevent';
  end if;
end $do$;

-- 2. No unilateral force path was ever added.
do $do$
declare v_found text;
begin
  select string_agg(p.proname, ', ') into v_found
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and (p.proname like '%restore%force%' or p.proname like '%force%restore%');
  if v_found is not null then
    raise exception
      'a forced-restore function exists (%) — memory_force_delete is reasonable '
      'for one memory row; for a relationship a unilateral path is a mechanism '
      'to force restoration on somebody who declined', v_found;
  end if;
end $do$;

-- 3. The table is RPC-only.
do $do$
begin
  if has_table_privilege('authenticated','public.couple_restore_requests','INSERT')
  or has_table_privilege('authenticated','public.couple_restore_requests','UPDATE')
  or has_table_privilege('authenticated','public.couple_restore_requests','DELETE')
  then
    raise exception
      'authenticated can write couple_restore_requests — confirmation must go '
      'through a function that checks who is asking, never a PATCH';
  end if;
end $do$;

-- 4. The safety exit is still reachable and still ungated. Re-asserted here
--    because THIS is the migration that could quietly make it conditional.
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='leave_couple_permanently';
  if v_src is null then
    raise exception 'leave_couple_permanently is gone — restore must never '
                    'exist without the way to refuse it';
  end if;
  if position('couple_restore_requests' in v_src) > 0 then
    raise exception
      'leave_couple_permanently now references the handshake — the exit must '
      'never be gated on the other person agreeing to it';
  end if;
end $do$;

-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   drop function if exists public.restore_couple();
--   drop function if exists public.couple_restore_confirm();
--   drop function if exists public.couple_restore_cancel();
--   drop function if exists public.couple_restore_request(text);
--   drop table    if exists public.couple_restore_requests;
--   create or replace function public.couple_restore_state() ...
--     -- the three-key form from 20260826160000
-- Drop couple_restore_state's new body LAST, or restore the old one first —
-- it reads the table.
--
-- Reversible. A couple restored before the rollback simply stays restored,
-- which is correct: rolling back the way back should not undo a reunion that
-- both people agreed to.
--
-- Second run: no-op. Table is IF NOT EXISTS, functions are create-or-replace,
-- the policy is dropped-if-exists first, and the assertions are read-only.
