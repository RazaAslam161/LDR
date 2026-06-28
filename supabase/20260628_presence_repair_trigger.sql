-- Function: auto-repair presence.couple_id whenever profiles.couple_id changes.
-- Fires on every pairing, re-pairing, and leaving. Presence always stays in
-- sync with profiles regardless of which code path caused the change.
CREATE OR REPLACE FUNCTION public.sync_presence_couple_id()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Profile's couple_id just changed (pairing or leaving)
  IF OLD.couple_id IS DISTINCT FROM NEW.couple_id THEN

    IF NEW.couple_id IS NULL THEN
      -- User left a couple: clear their presence couple_id
      UPDATE public.presence
        SET couple_id = NULL,
            is_online = FALSE,
            app_last_active_at = NULL,
            current_screen = NULL,
            updated_at = now()
        WHERE user_id = NEW.id;

    ELSE
      -- User joined a couple: update presence to new couple_id.
      -- Upsert so it works whether the presence row exists or not.
      INSERT INTO public.presence (user_id, couple_id, updated_at)
        VALUES (NEW.id, NEW.couple_id, now())
        ON CONFLICT (user_id)
        DO UPDATE SET
          couple_id = EXCLUDED.couple_id,
          updated_at = now();
    END IF;

  END IF;
  RETURN NEW;
END;
$$;

-- Attach trigger to profiles table
DROP TRIGGER IF EXISTS trg_sync_presence_couple_id ON public.profiles;

CREATE TRIGGER trg_sync_presence_couple_id
  AFTER UPDATE OF couple_id ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_presence_couple_id();

-- Also handle new profile creation (sign up flow).
-- New user: presence row created with correct couple_id.
CREATE OR REPLACE FUNCTION public.init_presence_on_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Create a presence row for every new profile.
  INSERT INTO public.presence (user_id, couple_id, updated_at)
    VALUES (NEW.id, NEW.couple_id, now())
    ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_init_presence ON public.profiles;

CREATE TRIGGER trg_init_presence
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.init_presence_on_profile();
