-- ───────────────────────────────────────────────────────────────────────────
-- Miles — intimacy layer additions
-- Run AFTER schema.sql. Idempotent so safe to re-run.
--
-- Adds:
--   - profiles.birth_date (age gate)
--   - couples.modest_mode (couples-wide intimacy-module hide toggle)
-- ───────────────────────────────────────────────────────────────────────────

alter table public.profiles
  add column if not exists birth_date date;

alter table public.couples
  add column if not exists modest_mode boolean not null default true;
-- default TRUE: intimacy module is hidden until BOTH partners explicitly enable.

-- ─── Constraint: nobody under 18 ────────────────────────────────────────────
-- Defensive — the app also blocks this client-side, but we hard-enforce it
-- at the DB level too so a malicious client can't bypass.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_must_be_adult'
  ) then
    alter table public.profiles
      add constraint profiles_must_be_adult
      check (
        birth_date is null or
        birth_date <= (current_date - interval '18 years')
      );
  end if;
end $$;

-- ─── Comment for clarity in the Supabase dashboard ──────────────────────────
comment on column public.profiles.birth_date is
  'Date of birth, used for the 18+ age gate. NULL until user completes onboarding.';
comment on column public.couples.modest_mode is
  'When true (default), the intimacy module is hidden for both partners. Both must opt out to reveal it.';
