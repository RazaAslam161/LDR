-- ───────────────────────────────────────────────────────────────────────────
-- Miles — pre-release hardening, 2026-08. Idempotent; safe to re-run.
--
-- This app was built for two people who trusted each other. Shipping it to
-- strangers changes the threat model completely: assume an attacker who has
-- signed up normally, holds a valid JWT, has decompiled the APK, and calls
-- PostgREST directly. Everything below closes a hole that only mattered once
-- that attacker existed.
--
-- Run this in the Supabase SQL editor AFTER schema.sql and every feature
-- migration. No data is deleted.
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1. CRITICAL: couple_id was a self-service membership card ──────────────
--
-- current_user_couple_id() reads profiles.couple_id, and every couple-scoped
-- policy in the schema resolves membership through it. profiles_update_self
-- allowed updating EVERY column of your own row, including that one. So:
--
--   PATCH /rest/v1/profiles?id=eq.<attacker-uid>  {"couple_id":"<victim>"}
--
-- passed `with check (id = auth.uid())` and made the attacker a member of any
-- couple whose UUID they knew — full read/write on chat, vault, body-map pins,
-- presence GPS, and the capsule-media bucket. Couple UUIDs are not secret:
-- they are the first path segment of every never-expiring couple_media URL.
--
-- Column-level REVOKE is the whole fix. PostgREST rejects any PATCH naming the
-- column; the SECURITY DEFINER pairing RPCs run as owner and are unaffected.
-- The Dart client never writes couple_id through the table API — only via RPC.
revoke update (couple_id) on public.profiles from authenticated, anon;

-- Belt and braces: even a future policy mistake cannot move a linked profile
-- into another couple, because the trigger refuses the transition outright
-- unless it comes from a SECURITY DEFINER function (which runs as the table
-- owner, not as `authenticated`).
create or replace function public.guard_couple_id()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.couple_id is distinct from old.couple_id
     and current_user = 'authenticated' then
    raise exception 'couple_id is not client-writable';
  end if;
  return new;
end; $$;
revoke execute on function public.guard_couple_id() from public, anon, authenticated;

drop trigger if exists trg_guard_couple_id on public.profiles;
create trigger trg_guard_couple_id
  before update of couple_id on public.profiles
  for each row execute function public.guard_couple_id();

-- ── 2. CRITICAL: a 6-character password to every dissolved relationship ────
--
-- couples.invite_code is 6 uppercase hex chars — 16.7M values — generated once
-- and never rotated, never expired, never invalidated. join_couple_by_code
-- checked only that the couple had fewer than 2 linked profiles, and
-- leave_couple() deliberately preserves all data while unlinking BOTH profiles.
-- Every couple that ever broke up was therefore a full chat/vault/media
-- archive sitting behind a 6-character code with no rate limit, and distinct
-- error strings ('invalid_code' vs 'couple_full') made a clean oracle.
--
-- The app does not use this path: joinCouple() in supabase_repository.dart has
-- no callers. Pairing goes through redeem_pairing_invite, which expires and is
-- single-use. So the legacy door is simply removed.
drop function if exists public.join_couple_by_code(text);

-- With that function gone nothing reads invite_code, but a 6-char secret left
-- lying in a table is a trap for whoever adds a lookup next. Retire the stored
-- codes and stop minting short ones. The column is NOT NULL, so it has to
-- become nullable before existing rows can be cleared.
alter table public.couples alter column invite_code drop not null;
update public.couples set invite_code = null where invite_code is not null;

-- create_couple's retry loop existed only to dodge collisions in a 6-char
-- space. Without a code to allocate there is nothing to collide.
create or replace function public.create_couple(p_timezone text)
returns public.couples language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_couple public.couples%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  -- Idempotent: if already linked, return the existing couple.
  select c.* into v_couple
  from public.couples c
  join public.profiles p on p.couple_id = c.id
  where p.id = v_uid;
  if found then return v_couple; end if;

  insert into public.couples (primary_tz) values (p_timezone)
  returning * into v_couple;

  update public.profiles set couple_id = v_couple.id where id = v_uid;
  return v_couple;
end; $$;
revoke execute on function public.create_couple(text) from public, anon;
grant  execute on function public.create_couple(text) to authenticated;

-- ── 3. Anyone could manufacture couples rows ──────────────────────────────
-- `with check (auth.uid() is not null)` let any signed-up account insert
-- arbitrary rows into public.couples and choose their own invite_code — i.e.
-- collide with, or squat on, a code. create_couple() is SECURITY DEFINER and
-- does the insert as owner, so the client never needs this policy at all.
drop policy if exists "couples_insert_authed" on public.couples;

-- ── 4. Either partner could rewrite the other's words ─────────────────────
-- messages_update_member scoped updates to the couple, not to the author, so
-- one partner could silently edit what the other had said — and the row is
-- what the other's client re-renders. Read receipts and the delete flags are
-- the only fields either side legitimately updates, and both go through
-- SECURITY DEFINER RPCs (hide_message / delete_message_for_everyone).
drop policy if exists "messages_update_member" on public.messages;
create policy "messages_update_own" on public.messages
  for update using (sender_id = auth.uid() and couple_id = public.current_user_couple_id())
  with check  (sender_id = auth.uid() and couple_id = public.current_user_couple_id());

-- ── 5. A sealed capsule could unseal itself ───────────────────────────────
-- capsules_update let the client PATCH unlocked_at directly, which is the
-- entire mechanism the sealed-until-date feature relies on. unlock_capsule()
-- is the SECURITY DEFINER path that checks the date; the client keeps every
-- other column.
revoke update (unlocked_at) on public.capsules from authenticated, anon;

-- ── 6. The PIN hash did not need to be readable ───────────────────────────
-- vault_pin_self is `for all`, so SELECT returned the row including pin_hash.
-- A 4-digit PIN has 10,000 candidates: with the hash in hand that is an
-- instant offline break, no rate limit involved. Nothing reads the hash
-- client-side — has_vault_pin()/verify_vault_pin() are SECURITY DEFINER and
-- read it as owner.
revoke select (pin_hash) on public.vault_pin from authenticated, anon;
