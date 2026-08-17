-- min_build was channel-blind: one row gates both the sideload fleet and the
-- (not yet shipped) Play channel. Raising it for a sideload migration would
-- hard-block every Play install onto a screen whose only rescue — self-update
-- — is deliberately absent there, and whose users update at Play-review and
-- auto-update speed, not R2 speed.
--
-- Additive: min_build_play, default 0, meaning "no floor". Shipped sideload
-- clients select explicit columns and never see it; the first Play client
-- reads it when its channel says play. Raising min_build_play is a deliberate
-- act, exactly like min_build.
--
-- Second run: no-op (add column if not exists).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Not applied here (drops are a separate later change, per the additive-only
-- rule), but for the record:
--   alter table public.app_release drop column min_build_play;
-- ───────────────────────────────────────────────────────────────────────────

alter table public.app_release
  add column if not exists min_build_play integer not null default 0;
