-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260820040411 on
-- 2026-08-20 04:04 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260820040000 so replay order stays correct against the
-- slot scheme the other files in this directory use.

alter table public.messages
  add column if not exists voice_peaks text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.messages'::regclass
      and conname = 'messages_voice_peaks_len'
  ) then
    alter table public.messages
      add constraint messages_voice_peaks_len
      check (voice_peaks is null or length(voice_peaks) <= 256);
  end if;
end $$;

comment on column public.messages.voice_peaks is
  'The recording''s own levels, drawn as the waveform on the voice bubble: base64 of one byte per bar (0 = silence, 255 = full scale), 56 bars as of this build. Sampled from the microphone on the sender''s device at 100ms and reduced by loudest-in-bucket. Null means the note carries no shape — sent before this column, sent by an older client, or recorded with no levels available — and the bubble draws a per-message pattern derived from the message id instead. Never a row of zeros: that would claim the recording is silent.';
