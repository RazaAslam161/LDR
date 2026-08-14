-- Heal-on-read needs to null photo_cipher/photo_nonce once the photograph has
-- been re-encrypted into memory_photos. 007100's column grant deliberately does
-- not include them — the client holds UPDATE on eight cipher/nonce/link columns
-- and nothing else — so this is the door, and it is a narrow one on purpose.
--
-- The interesting part is the EXISTS clause. `thumb_backfill` states the rule
-- the hard way in a comment: upload, THEN claim, and never the reverse, because
-- claiming with nothing behind it makes the object path non-null everywhere at
-- once and every surface switches to a path that 404s — permanently, with no
-- way back, since the legacy branch is never entered again.
--
-- Here that rule is not a comment. Nulling the inline photo is only possible
-- once a memory_photos row for that memory exists, so a client that clears
-- first and uploads second cannot destroy the only copy of a photograph whose
-- key exists on exactly two devices in the world. Ordering enforced by the
-- database instead of by remembering.
create or replace function public.memory_clear_inline_photo(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads t
     set photo_cipher = null, photo_nonce = null
   where t.id = p_id
     and t.couple_id = (select public.current_user_couple_id())
     and t.photo_cipher is not null
     and exists (select 1 from public.memory_photos p where p.memory_id = t.id);
  if not found then
    raise exception 'nothing to clear, or no replacement photo exists yet';
  end if;
end $fn$;

revoke all on function public.memory_clear_inline_photo(uuid) from public, anon;
grant execute on function public.memory_clear_inline_photo(uuid) to authenticated;
