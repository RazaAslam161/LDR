-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the UI-sound kill switch, and why its polarity is inverted.
--
-- The app is growing a sound layer: short cues at ceremonial moments and one
-- ambient bed, all decoded through the platform's software Vorbis path. Audio
-- has a class of failure that only exists in the field — an OEM decoder that
-- ANRs, an audio-focus fight with a dialer — and the sideload fleet has
-- already proved that waiting for an install day is waiting for an event that
-- does not happen. If a device population misbehaves, the way back has to be
-- one statement:
--
--   update public.app_release set ui_sound_kill = true;
--
-- Note the polarity: ads_enabled fails OFF because serving a wrong ad cannot
-- be undone. Sound is the opposite — the safe failure is a WORKING feature
-- that follows the on-device toggle. So the column names the exceptional
-- action (a kill), and absent/false — an unmigrated environment, a fallback
-- column list, an unreachable gate — all read "not killed": sound stays under
-- the user's own control.
--
-- Re-runnable: `add column if not exists` makes a second run a no-op. No RLS
-- change — app_release is already select-only to anon and authenticated with
-- every write revoked (20260601004800_client_version_gate.sql).
--
-- Rollback:
--   alter table public.app_release drop column if exists ui_sound_kill;
-- Safe at any time. Clients read this column through a select that degrades
-- to the previous column list when a column is missing, so dropping it
-- returns sound to the local toggle rather than breaking the release gate.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.app_release
  add column if not exists ui_sound_kill boolean not null default false;

comment on column public.app_release.ui_sound_kill is
  'Fleet-wide UI-sound kill switch. True means no client plays a cue; '
  'absent or false means sound follows the on-device toggle.';
