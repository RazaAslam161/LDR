-- Fix leave_couple() RPC to also clean up presence rows.
-- The original function left presence.couple_id pointing
-- to the old dead couple, causing everything to break
-- when users re-paired. This version cleans presence too,
-- and additionally clears app_last_active_at so a stale
-- "online" can't survive the unlink.
CREATE OR REPLACE FUNCTION public.leave_couple()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_couple_id uuid;
  v_uid uuid;
BEGIN
  v_uid := auth.uid();

  SELECT couple_id INTO v_couple_id
  FROM public.profiles
  WHERE id = v_uid;

  IF v_couple_id IS NULL THEN
    RETURN;
  END IF;

  -- Null out both partners profiles
  UPDATE public.profiles
    SET couple_id = NULL
    WHERE couple_id = v_couple_id;

  -- Mark couple inactive
  UPDATE public.couples
    SET active = FALSE
    WHERE id = v_couple_id;

  -- FIX: Clean up presence rows so they dont point
  -- to the dead couple after re-pairing
  UPDATE public.presence
    SET couple_id = NULL,
        is_online = FALSE,
        app_last_active_at = NULL,
        updated_at = now()
    WHERE couple_id = v_couple_id;

END;
$$;

REVOKE EXECUTE ON FUNCTION public.leave_couple()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.leave_couple()
  TO authenticated;
