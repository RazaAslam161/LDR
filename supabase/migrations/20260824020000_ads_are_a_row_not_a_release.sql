-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the ads switch, and why it is a column rather than a build flag.
--
-- The app's one banner sits on the Touch tab, which draws a photograph the
-- couple uploaded, out of a bucket the server cannot read. Google enforces its
-- publisher policy against the ACCOUNT, and AdMob and AdSense are one publisher
-- identity — so the cost of being wrong about that screen is not a broken
-- feature, it is earnings that have nothing to do with this app.
--
-- A compile-time flag cannot undo that. Turning ads off in a release means
-- waiting for installs, and the sideload fleet has already proved that waiting
-- for an install day is waiting for an event that does not happen. This column
-- makes the way back one statement:
--
--   update public.app_release set ads_enabled = false;
--
-- Default FALSE, and the client defaults false again on its own side, so an
-- environment that never runs this migration and an environment that cannot be
-- reached both land on "no ads". There is no failure mode that serves.
--
-- Re-runnable: `add column if not exists` makes a second run a no-op. No RLS
-- change — app_release is already select-only to anon and authenticated with
-- every write revoked (20260601004800_client_version_gate.sql).
--
-- Rollback:
--   alter table public.app_release drop column if exists ads_enabled;
-- Safe at any time. Clients read this column through a select that already
-- falls back to the pre-existing column list when a column is missing, so
-- dropping it turns ads off rather than breaking the release gate.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.app_release
  add column if not exists ads_enabled boolean not null default false;

comment on column public.app_release.ads_enabled is
  'Fleet-wide AdMob kill switch. False means no client requests an ad.';
