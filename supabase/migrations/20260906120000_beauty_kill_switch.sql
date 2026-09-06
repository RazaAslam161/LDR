-- beauty_kill: the remote off switch for the camera retouch (BRAIN §287).
--
-- The retouch is a native GL pipeline compiled into every install. A GPU driver
-- that mishandles it — a black viewfinder, a stuck capturer — is a
-- device-population bug found in the field, and the way back has to be one
-- UPDATE, not a release cycle waiting on installs. Same shape and polarity as
-- ui_sound_kill: absent or false means the feature follows the local toggle.
--
-- Additive only. Clients read it through their own column generation
-- (release_gate.dart, withBeautyKill) and fall back to the older generation on
-- an environment that lacks it, so applying this in either order is safe.
--
-- Second run: no-op (IF NOT EXISTS).
-- Rollback:   alter table public.app_release drop column beauty_kill;
--             (clients fall back to withSoundKill on the next launch; nothing
--             else reads the column.)

alter table public.app_release
  add column if not exists beauty_kill boolean not null default false;

comment on column public.app_release.beauty_kill is
  'Remote kill for the camera retouch. false = follows the local toggle.';
