-- A voice note has never carried its own length.
--
-- The bubble draws a play button and eighteen bars, and the bars are pure
-- decoration — List.generate(18, ...) with a height derived from the bar's
-- index, so a two-second note and a two-minute note are drawn identically. The
-- only way to learn how long a note runs is to play it to the end. The owner's
-- words: "Every voice note should show its length — 2 seconds, 3 seconds".
--
-- The recorder cannot supply the number: record 7.1.0's stop() returns the
-- path and nothing else, and the package's only Duration is the amplitude
-- polling interval. The client reads it out of the recording's own m4a mvhd
-- box — what the encoder wrote down when it closed the file — and sends it
-- here with the row.
--
-- ROLLBACK (this undoes the forward change below):
--
--   alter table public.messages drop column if exists voice_duration_ms;
--
-- Dropping it is safe in a way that dropping most columns is not. Exactly one
-- thing reads it — the label on the voice bubble — and a null there is already
-- a shipped, permanent state (see below), so the column's absence degrades to
-- a render the app draws every day anyway. No view, index, policy, trigger or
-- function references it.
--
-- A SECOND RUN IS A NO-OP. `add column if not exists` is the whole of the
-- change, and `comment on column` is an overwrite by definition.
--
-- Nullable, and nothing anywhere requires it. Two populations keep it null
-- forever rather than transitionally:
--   1. The 12 voice notes already sent as of 2026-08-17. Nothing backfills
--      them — the duration is not recoverable from the row, only from the
--      audio, and re-deriving it would mean downloading and decoding every
--      note in every couple's history to win a label.
--   2. Every note from a client older than this build. The fleet is sideloaded
--      with no update channel, so those inserts keep arriving indefinitely.
-- The bubble treats null as "length unknown" and draws no label at all, which
-- is exactly how all 12 of those notes look today.

alter table public.messages
  add column if not exists voice_duration_ms integer;

comment on column public.messages.voice_duration_ms is
  'How long the voice note runs, in MILLISECONDS, read from the recording''s own m4a mvhd box at send time. Null means unknown: everything sent before this column existed, and anything from a client that predates it. Milliseconds rather than whole seconds so a later waveform or scrubber does not need a second column — the bubble rounds to seconds itself for the label.';
