-- Dual consent was enforced only in Dart. 006800 closed the DELETE half; this
-- closes the UPDATE half, which is the larger one.
--
-- Verified live before this ran: authenticated held INSERT, SELECT, UPDATE on
-- memory_threads and memory_threads_update_member permits writing ANY column of
-- any row in the couple. "Your partner must confirm" was a client-side if
-- (memory_threads_screen.dart:846-848) over a policy that let the row be
-- rewritten into any state the caller liked — accepted, deleted, attributed to
-- whoever — with one PostgREST call.
--
-- The fix is column privileges rather than a trigger plus a GUC: PostgREST
-- enforces column-level grants, SECURITY DEFINER functions run as owner and are
-- unaffected, and there is no bypass flag to reason about.
--
-- BREAKING for installed builds. Build 20 updates state/accepted_by/archived_at
-- directly and those calls now 403. That is deliberate and the cost is
-- measurable: nine rows exist across two couples and every one is still
-- 'proposed', so the accept path being broken breaks a path nobody has ever
-- completed. The RPCs below replace it in the same release.
alter table public.memory_threads add column if not exists delete_prior_state text;

revoke select, delete on public.memory_threads from anon;
revoke delete, update on public.memory_threads from authenticated;

-- The grant list is the security boundary. It deliberately omits id, couple_id,
-- proposer, happened_on, state, accepted_by/at, archived_at,
-- delete_requested_by/at, deleted_by/at, delete_prior_state, photo_count,
-- last_photo_at, cover_path, cover_tile_path.
--
-- proposer's omission is not cosmetic. With it writable, A proposes M, sets
-- proposer = B's uuid (policy passes, couple_id unchanged), then calls
-- memory_accept — whose `proposer <> auth.uid()` now holds. A alone produces an
-- accepted memory attributed to B, with A's own text in the "she wrote" slot.
-- 006800's trigger already blocks the rewrite; this removes the ability to
-- attempt it, so the guarantee no longer rests on one trigger staying installed.
grant update (title_cipher, title_nonce, note_cipher, note_nonce,
              place_cipher, place_nonce, cover_photo_id, visit_id)
  on public.memory_threads to authenticated;

-- ── The same door, still open on four other tables ─────────────────────────
-- 001400's do-loop created identical *_delete_member policies for vault_items,
-- afterglow_entries, couple_dissolutions and rituals. Each has a request →
-- confirm flow in the client and each can be skipped entirely with a plain
-- DELETE, exactly as memory_threads could until 006800. 006900 could not reach
-- them because it only revoked DELETE where no policy existed — here the policy
-- is the problem.
--
-- Verified before dropping: no Dart call site issues a hard delete against any
-- of the four. The only `.delete()` calls in Closer are body_map_pins and
-- fantasy_jar_entries, which are single-owner rows with no consent flow.
do $do$
declare t text;
begin
  foreach t in array array['vault_items','afterglow_entries','couple_dissolutions','rituals']
  loop
    execute format('drop policy if exists %I on public.%I', t||'_delete_member', t);
    execute format('revoke delete on public.%I from authenticated, anon', t);
  end loop;
end $do$;

-- ── Lifecycle ──────────────────────────────────────────────────────────────
-- Same shape as claim_thumb (006200): SECURITY DEFINER, one row, inside the
-- caller's own couple, one transition each, actor asserted against auth.uid()
-- rather than taken as a parameter.

-- Accepting is the PARTNER's act. Notes are OPTIONAL — passing nulls is the
-- one-tap path, and authored acceptance is offered afterwards, not as a gate.
-- Making the only transition running at zero more expensive is not a fix.
create or replace function public.memory_accept(
  p_id uuid, p_note_cipher bytea default null, p_note_nonce bytea default null)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  if (p_note_cipher is null) <> (p_note_nonce is null) then
    raise exception 'note cipher and nonce move together'; end if;
  update public.memory_threads
     set state='accepted', accepted_by=auth.uid(), accepted_at=now(),
         partner_note_cipher=coalesce(p_note_cipher, partner_note_cipher),
         partner_note_nonce =coalesce(p_note_nonce,  partner_note_nonce)
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='proposed' and proposer is distinct from auth.uid();
  if not found then raise exception 'not yours to accept'; end if;
end $fn$;

-- Writing your side after the fact.
create or replace function public.memory_set_partner_note(
  p_id uuid, p_note_cipher bytea, p_note_nonce bytea)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  if (p_note_cipher is null) <> (p_note_nonce is null) then
    raise exception 'note cipher and nonce move together'; end if;
  update public.memory_threads
     set partner_note_cipher=p_note_cipher, partner_note_nonce=p_note_nonce
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and accepted_by = auth.uid() and state in ('accepted','archived');
  if not found then raise exception 'not yours'; end if;
end $fn$;

create or replace function public.memory_set_state(p_id uuid, p_state text)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  if p_state not in ('accepted','archived') then raise exception 'bad state'; end if;
  update public.memory_threads
     set state=p_state, archived_at = case when p_state='archived' then now() else null end
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state in ('accepted','archived');
  if not found then raise exception 'not found'; end if;
end $fn$;

-- The state ALL NINE production rows are stuck in has no action at all today:
-- _actions() has exactly one 'proposed' branch and it requires !isMine, so the
-- Wrap renders empty for the person who created it.
create or replace function public.memory_withdraw(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads set state='deleted', deleted_by=auth.uid(), deleted_at=now()
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='proposed' and proposer = auth.uid();
  if not found then raise exception 'not yours to withdraw'; end if;
end $fn$;

-- 'archived' is admitted: today Request delete is gated on accepted only
-- (screen.dart:837), so archiving permanently removes the only path to
-- deleting, and nothing in the UI says so. prior_state is stashed so that
-- cancelling an archived row does not silently unarchive it.
create or replace function public.memory_request_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set state='deletion_requested', delete_prior_state=state,
         delete_requested_by=auth.uid(), delete_requested_at=now()
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state in ('accepted','archived');
  if not found then raise exception 'not found'; end if;
end $fn$;

-- Either partner may cancel. The repository's own comment already says exactly
-- this ("either can veto by cancelling", repository.dart:295-297) and the UI
-- contradicted it by showing Cancel only to the requester.
create or replace function public.memory_cancel_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set state=coalesce(delete_prior_state,'accepted'), delete_prior_state=null,
         delete_requested_by=null, delete_requested_at=null,
         archived_at = case when coalesce(delete_prior_state,'accepted')='archived'
                            then archived_at else null end
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='deletion_requested';
  if not found then raise exception 'not found'; end if;
end $fn$;

-- THE dual-consent assertion. This one line is the whole guarantee and it
-- cannot live in the client.
create or replace function public.memory_confirm_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set state='deleted', deleted_by=auth.uid(), deleted_at=now()
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='deletion_requested' and delete_requested_by is distinct from auth.uid();
  if not found then raise exception 'only your partner can confirm this'; end if;
end $fn$;

-- The requester's escape hatch, on the SERVER's clock. The vault computes its
-- 14 days from DateTime.now() on the handset (private_vault_repository.dart:
-- 139-141), so a wrong device clock reaches expiry early or never — in a
-- codebase that already argues client clocks are untrustworthy (ServerClock).
--
-- Kept despite the argument that it is one verb too many: with proposer now ON
-- DELETE SET NULL, a sole surviving partner has no other exit.
create or replace function public.memory_force_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set state='deleted', deleted_by=auth.uid(), deleted_at=now()
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='deletion_requested' and delete_requested_by = auth.uid()
     and delete_requested_at < now() - interval '14 days';
  if not found then raise exception 'not yet'; end if;
end $fn$;

do $do$ declare f text; begin
  foreach f in array array[
    'memory_accept(uuid,bytea,bytea)','memory_set_partner_note(uuid,bytea,bytea)',
    'memory_set_state(uuid,text)','memory_withdraw(uuid)','memory_request_delete(uuid)',
    'memory_cancel_delete(uuid)','memory_confirm_delete(uuid)','memory_force_delete(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon;', f);
    execute format('grant execute on function public.%s to authenticated;', f);
  end loop;
end $do$;

-- The grant list above is only true if it stays true. Assert it, so a later
-- `grant update on memory_threads to authenticated` fails the migration that
-- writes it rather than quietly reopening the door.
do $do$
declare bad text;
begin
  if has_table_privilege('authenticated', 'public.memory_threads', 'UPDATE') then
    select string_agg(a.attname, ', ' order by a.attname) into bad
      from pg_attribute a
     where a.attrelid='public.memory_threads'::regclass and a.attnum > 0 and not a.attisdropped
       and has_column_privilege('authenticated', a.attrelid, a.attnum, 'UPDATE')
       and a.attname not in ('title_cipher','title_nonce','note_cipher','note_nonce',
                             'place_cipher','place_nonce','cover_photo_id','visit_id');
    if bad is not null then
      raise exception 'memory_threads: authenticated can still write %', bad;
    end if;
  end if;
  if has_table_privilege('authenticated', 'public.memory_threads', 'DELETE') then
    raise exception 'memory_threads: authenticated still holds DELETE';
  end if;
end $do$;
