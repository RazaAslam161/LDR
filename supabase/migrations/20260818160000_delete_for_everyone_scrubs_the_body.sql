-- §63 follow-up: "delete for everyone" hid the message and kept its text.
--
-- delete_message_for_everyone set the flag and reaped the media, but body,
-- body_cipher and body_nonce stayed in the row forever — content both
-- partners watched disappear, still at rest server-side, still readable by
-- anyone with database access, and still exported by any future admin dump.
-- For the one action whose entire meaning is "this text no longer exists",
-- the text existed.
--
-- Fix: the same UPDATE that sets the flag now nulls all three columns
-- (the pair CHECK from 20260818100000 is (cipher null) = (nonce null) —
-- nulling both satisfies it). Media paths stay: their objects are reaped by
-- the queue below and a dangling name in a reaped bucket reads nothing.
-- Delete-for-me is untouched on purpose — that is a per-user hide and the
-- partner keeps their copy.
--
-- Backfill: rows deleted-for-everyone before this migration get the same
-- scrub, once, with the count logged. Shipped clients already render these
-- rows from the flag alone, so nulling the text changes no pixel.
--
-- Second run: RPC replace is a no-op; the backfill matches zero rows.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   Re-run delete_message_for_everyone from 20260817130000 lines 33-55 (the
--   version whose UPDATE sets only the flag and timestamp). The backfilled
--   bodies are gone and cannot be rolled back — that is the point of the
--   change; do not apply it anywhere that is not ready for that.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.delete_message_for_everyone(p_message_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_image text; v_voice text; v_video text; v_file text;
begin
  update public.messages
     set deleted_for_everyone = true, deleted_at = now(),
         body = null, body_cipher = null, body_nonce = null
   where id = p_message_id and sender_id = auth.uid()
  returning image_path, voice_path, video_path, file_path
       into v_image, v_voice, v_video, v_file;

  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from storage.objects o
   where (o.bucket_id = 'couple_media'
            and o.name in (v_image, v_voice,
                           regexp_replace(v_image, '([^/]*)$', 'thumb/\1')))
      or (o.bucket_id = 'couple_intimate'
            and o.name in (v_video,
                           regexp_replace(v_video, '([^/]*)$', 'thumb/\1')))
      or (o.bucket_id = 'couple_files'    and o.name = v_file)
  on conflict do nothing;
end $fn$;

do $do$
declare v_count int;
begin
  update public.messages
     set body = null, body_cipher = null, body_nonce = null
   where deleted_for_everyone
     and (body is not null or body_cipher is not null);
  get diagnostics v_count = row_count;
  raise warning 'delete_for_everyone backfill: scrubbed % previously deleted rows',
    v_count;
end $do$;
