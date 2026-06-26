-- Migration: WhatsApp-grade presence — three isolated timestamps.
-- Project: sopictusdonlvuezmfep
-- Applied 2026-06-27 (via Supabase MCP). Safe to re-run (idempotent).
--
-- Field 1: app_last_active_at
--   Written ONLY by genuine app usage (online/typing/chat/mood/screen/etc.).
--   NEVER written by GPS/location updates.
--   Drives: Online/Last-seen subtitle, delivered tick, online dot.
-- Field 2: chat_last_read (already exists) — written only by setChatLastRead
--   (5s timer while the chat is open). Drives: seen tick, "is here" avatar.
-- Field 3: location_updated_at (already exists) — written only by setLiveLocation
--   (GPS). Drives: map pin LIVE badge, location-card freshness.

ALTER TABLE public.presence
  ADD COLUMN IF NOT EXISTS app_last_active_at timestamptz;

-- Backfill from last_seen (written ONLY by setOnline — open/resume/close —
-- never by GPS), so there's no null gap on first launch. Do NOT backfill from
-- updated_at: GPS bumps updated_at, so it would seed a polluted value for users
-- whose app is closed but whose location service is still pinging.
UPDATE public.presence
  SET app_last_active_at = last_seen
  WHERE last_seen IS NOT NULL;

-- Verify:
-- SELECT user_id, app_last_active_at, chat_last_read,
--        location_updated_at, updated_at FROM public.presence;
