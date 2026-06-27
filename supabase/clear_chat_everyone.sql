-- Drop old soft-delete clear
DROP FUNCTION IF EXISTS public.clear_conversation();

-- New function: hard delete all messages for both users in the couple
CREATE OR REPLACE FUNCTION public.clear_conversation_everyone()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_couple_id uuid;
BEGIN
  SELECT couple_id INTO v_couple_id
  FROM public.profiles
  WHERE id = auth.uid();

  IF v_couple_id IS NULL THEN
    RAISE EXCEPTION 'not_paired';
  END IF;

  DELETE FROM public.messages
  WHERE couple_id = v_couple_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.clear_conversation_everyone() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.clear_conversation_everyone() TO authenticated;
