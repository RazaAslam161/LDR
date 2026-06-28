-- leave_couple(): on unlink, clear ALL sensitive presence data for both
-- partners so a future new partner can never see the previous partner's
-- location, mood, body photo, or screen activity.
--
-- ORDERING NOTE (important): trg_sync_presence_couple_id (see
-- 20260628_presence_repair_trigger.sql) nulls presence.couple_id the moment
-- profiles.couple_id changes. So the sensitive-field clear below MUST run
-- BEFORE the profiles UPDATE — otherwise its `WHERE couple_id = v_couple_id`
-- would match zero rows (couple_id already nulled by the trigger) and the
-- private fields would never be wiped. The profiles UPDATE then fires the
-- trigger, which re-nulls couple_id idempotently.
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
  FROM public.profiles WHERE id = v_uid;

  IF v_couple_id IS NULL THEN RETURN; END IF;

  -- 1) Clear ALL sensitive presence data for both partners FIRST, while
  --    couple_id still matches (see ORDERING NOTE above).
  UPDATE public.presence
    SET couple_id = NULL,
        is_online = FALSE,
        app_last_active_at = NULL,
        current_screen = NULL,
        current_mood = NULL,
        mood_color = NULL,
        latitude = NULL,
        longitude = NULL,
        location_label = NULL,
        location_sharing_mode = 'off',
        location_updated_at = NULL,
        body_photo_path = NULL,
        checkin_photo_url = NULL,
        checkin_photo_at = NULL,
        avatar_emoji = NULL,
        chat_last_read = NULL,
        updated_at = now()
    WHERE couple_id = v_couple_id;

  -- 2) Null out both partners' profiles (fires trg_sync_presence_couple_id,
  --    which re-nulls presence.couple_id idempotently).
  UPDATE public.profiles
    SET couple_id = NULL
    WHERE couple_id = v_couple_id;

  -- 3) Mark couple inactive
  UPDATE public.couples
    SET active = FALSE
    WHERE id = v_couple_id;

END;
$$;

REVOKE EXECUTE ON FUNCTION public.leave_couple()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.leave_couple()
  TO authenticated;
