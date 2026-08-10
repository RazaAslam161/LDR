-- call_invites table for WebRTC durable offer storage
-- Required for calling a closed/backgrounded app
CREATE TABLE IF NOT EXISTS public.call_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  couple_id uuid REFERENCES public.couples(id)
    ON DELETE CASCADE,
  caller_id uuid REFERENCES public.profiles(id)
    ON DELETE CASCADE,
  callee_id uuid REFERENCES public.profiles(id)
    ON DELETE CASCADE,
  offer_sdp text NOT NULL,
  video boolean NOT NULL DEFAULT false,
  created_at timestamptz DEFAULT now(),
  answered_at timestamptz
);

ALTER TABLE public.call_invites
  ENABLE ROW LEVEL SECURITY;

-- NOTE: Postgres has no `CREATE POLICY IF NOT EXISTS`, so drop-then-create
-- keeps this migration idempotent / safe to re-run.
DROP POLICY IF EXISTS "call_invites_couple" ON public.call_invites;
CREATE POLICY "call_invites_couple"
  ON public.call_invites
  FOR ALL USING (
    couple_id = public.current_user_couple_id()
  );

ALTER TABLE public.call_invites
  REPLICA IDENTITY FULL;

-- Add to the realtime publication only if it isn't already a member
-- (ADD TABLE errors on a duplicate), so this stays re-runnable.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'call_invites'
  ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.call_invites;
  END IF;
END $$;
