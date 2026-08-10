-- Add app activity timestamp column
-- Separates genuine app activity from GPS location writes
-- Used by isTrulyOnline getter (45s freshness window)
ALTER TABLE public.presence
  ADD COLUMN IF NOT EXISTS app_last_active_at timestamptz;

-- Add current screen column
-- Shows partner which feature you are currently in
ALTER TABLE public.presence
  ADD COLUMN IF NOT EXISTS current_screen text;

-- Backfill app_last_active_at from updated_at
UPDATE public.presence
  SET app_last_active_at = updated_at
  WHERE app_last_active_at IS NULL;
