-- Ending takes seven days.
--
-- The hold-to-end gesture dissolved a couple in 1200 milliseconds, which is
-- exactly the speed of a fight. This replaces it with a ceremony: starting an
-- unlink opens a 7-day window BOTH people can see; the partner can write one
-- sealed note that appears on the initiator's re-link screen; accepting moves
-- to a 24-hour last look; a single tap from the initiator cancels everything,
-- any day, until the moment it executes.
--
-- LAWS this file is built on:
--  * The ceremony is a SCHEDULING LAYER. leave_couple(),
--    leave_couple_permanently() and purge_couple() are byte-untouched, and
--    assertion #4 below turns that into a property: the exits may never
--    reference couple_unlink. Leaving can be slowed, never blocked.
--  * Execution happens on HUMAN PRESENCE: either member's phone, past the
--    deadline, calls unlink_execute(). There is deliberately NO cron and no
--    impersonation shim here — a scheduled robot never ends a relationship.
--    (Both phones abandoned forever leaves the couple standing, exactly as
--    the app behaves today.)
--  * Re-link wins until execution: cancel works in ANY state.
--  * Accepting can never EXTEND the ceremony: the last look is clamped to
--    the cooling deadline.
--  * The row dies with the couple by ANY exit (trigger below), so an
--    emergency severance mid-ceremony followed months later by the restore
--    handshake can never resurrect a stale, past-deadline ceremony that
--    executes an unlink nobody remembers asking for.

-- ── The ceremony row ─────────────────────────────────────────────────────

create table if not exists public.couple_unlink (
  couple_id         uuid primary key
                    references public.couples(id) on delete cascade,
  initiated_by      uuid not null
                    references public.profiles(id) on delete cascade,
  state             text not null default 'cooling'
                    check (state in ('cooling', 'last_look')),
  started_at        timestamptz not null default now(),
  cooling_ends_at   timestamptz not null,
  accepted_by       uuid references public.profiles(id) on delete set null,
  accepted_at       timestamptz,
  last_look_ends_at timestamptz,
  -- The partner's one sealed note (mac || ciphertext, nonce beside it) —
  -- ciphertext only, the same no-plaintext-at-rest law as chat.
  note_cipher       bytea,
  note_nonce        bytea,
  note_author       uuid references public.profiles(id) on delete set null,
  note_updated_at   timestamptz,
  updated_at        timestamptz not null default now(),
  constraint couple_unlink_note_size
    check (note_cipher is null or octet_length(note_cipher) <= 8192),
  constraint couple_unlink_last_look
    check ((state = 'last_look') = (last_look_ends_at is not null))
);

alter table public.couple_unlink enable row level security;

-- Reads via RLS select; every write via the RPCs below.
revoke all on public.couple_unlink from anon, authenticated;
grant select on public.couple_unlink to authenticated;

drop policy if exists couple_unlink_visible on public.couple_unlink;
create policy couple_unlink_visible on public.couple_unlink
  for select using (couple_id = (select public.current_user_couple_id()));

-- Realtime: the far phone must see the row appear, the note land, and a
-- cancel clear the banner, live. (The execute-DELETE may not be delivered —
-- by then current_user_couple_id() is null on both sides — and that is fine:
-- the far phone discovers by fetch, exactly as severance works today.)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and tablename = 'couple_unlink'
  ) then
    alter publication supabase_realtime add table public.couple_unlink;
  end if;
end $$;

-- ── The RPCs ─────────────────────────────────────────────────────────────

create or replace function public.unlink_start()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then raise exception 'no_active_couple'; end if;
  if not exists (
    select 1 from public.couples where id = v_couple and active
  ) then
    raise exception 'no_active_couple';
  end if;
  begin
    insert into public.couple_unlink (couple_id, initiated_by, cooling_ends_at)
    values (v_couple, v_uid, now() + interval '7 days');
  exception when unique_violation then
    raise exception 'already_started';
  end;
end;
$$;

create or replace function public.unlink_cancel()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;
  -- Initiator only, ANY state: re-link wins until execution. Silent when
  -- there is nothing to cancel.
  delete from public.couple_unlink
   where couple_id = v_couple and initiated_by = v_uid;
end;
$$;

create or replace function public.unlink_accept()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then raise exception 'no_active_couple'; end if;
  -- least(): accepting on day 6 must not stretch the ceremony past day 7.
  update public.couple_unlink
     set state             = 'last_look',
         accepted_by       = v_uid,
         accepted_at       = now(),
         last_look_ends_at = least(cooling_ends_at, now() + interval '24 hours'),
         updated_at        = now()
   where couple_id = v_couple
     and state = 'cooling'
     and initiated_by is distinct from v_uid;
  if not found then raise exception 'nothing_to_accept'; end if;
end;
$$;

create or replace function public.unlink_write_note(
  p_cipher bytea,
  p_nonce  bytea
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if (p_cipher is null) <> (p_nonce is null) then
    raise exception 'note_halves_mismatch';
  end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then raise exception 'no_active_couple'; end if;
  -- The PARTNER writes to the initiator, never the reverse — the note is the
  -- voice of the person being left. Both-null clears it.
  update public.couple_unlink
     set note_cipher     = p_cipher,
         note_nonce      = p_nonce,
         note_author     = case when p_cipher is null then null else v_uid end,
         note_updated_at = case when p_cipher is null then null else now() end,
         updated_at      = now()
   where couple_id = v_couple
     and initiated_by is distinct from v_uid;
  if not found then raise exception 'nothing_to_write_on'; end if;
end;
$$;

create or replace function public.unlink_execute()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
  v_due    timestamptz;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  -- Silent when there is nothing to execute: the other phone may have won
  -- the race, and this call must never confirm or deny anything.
  if v_couple is null then return; end if;
  select coalesce(last_look_ends_at, cooling_ends_at) into v_due
    from public.couple_unlink where couple_id = v_couple;
  if v_due is null then return; end if;
  if now() < v_due then raise exception 'not_yet'; end if;
  -- auth.uid() survives nested SECURITY DEFINER calls (the
  -- leave_couple_permanently precedent), so the untouched exit does all the
  -- real work: storage reap, the 21-column presence scrub, invites, the
  -- couples row. Its dissolved_at write fires trg_unlink_dies_with_couple,
  -- which removes this ceremony row in the same transaction; the delete
  -- below is the belt to that trigger's braces.
  perform public.leave_couple();
  delete from public.couple_unlink where couple_id = v_couple;
end;
$$;

revoke execute on function public.unlink_start()                 from public, anon;
revoke execute on function public.unlink_cancel()                from public, anon;
revoke execute on function public.unlink_accept()                from public, anon;
revoke execute on function public.unlink_write_note(bytea, bytea) from public, anon;
revoke execute on function public.unlink_execute()               from public, anon;
grant execute on function public.unlink_start()                  to authenticated;
grant execute on function public.unlink_cancel()                 to authenticated;
grant execute on function public.unlink_accept()                 to authenticated;
grant execute on function public.unlink_write_note(bytea, bytea) to authenticated;
grant execute on function public.unlink_execute()                to authenticated;

-- ── The row dies with the couple, by ANY exit ────────────────────────────

create or replace function public.unlink_dies_with_couple()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.couple_unlink where couple_id = new.id;
  return new;
end;
$$;

revoke execute on function public.unlink_dies_with_couple()
  from public, anon, authenticated;

drop trigger if exists trg_unlink_dies_with_couple on public.couples;
create trigger trg_unlink_dies_with_couple
  after update of dissolved_at on public.couples
  for each row
  when (old.dissolved_at is null and new.dissolved_at is not null)
  execute function public.unlink_dies_with_couple();

-- ── Tell the partner, immediately ────────────────────────────────────────
--
-- Explicit non-sensitive columns only — never note_cipher. The edge function
-- resolves the recipient (the member who is not initiated_by) and sends a
-- data-only push the client renders quietly.

create or replace function public.notify_unlink()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text := public.functions_base_url();
begin
  if v_url is null then
    raise warning 'notify_unlink: functions_base_url not configured';
    return new;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/reach-notify',
    body    := jsonb_build_object(
      'kind', 'unlink',
      'record', jsonb_build_object(
        'couple_id',    new.couple_id,
        'initiated_by', new.initiated_by
      )
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-notify-secret', coalesce(public.notify_secret(), '')
    )
  );
  return new;
end;
$$;

revoke execute on function public.notify_unlink()
  from public, anon, authenticated;

drop trigger if exists couple_unlink_notify on public.couple_unlink;
create trigger couple_unlink_notify
  after insert on public.couple_unlink
  for each row
  execute function public.notify_unlink();

-- ── Assertions ───────────────────────────────────────────────────────────

do $$
begin
  -- 1. The table takes no client writes.
  if has_table_privilege('authenticated', 'public.couple_unlink', 'INSERT')
     or has_table_privilege('authenticated', 'public.couple_unlink', 'UPDATE')
     or has_table_privilege('authenticated', 'public.couple_unlink', 'DELETE')
  then
    raise exception 'couple_unlink must be RPC-only for writes';
  end if;

  -- 2. The trigger functions are unreachable by client roles.
  if has_function_privilege('authenticated',
       'public.unlink_dies_with_couple()', 'EXECUTE')
     or has_function_privilege('authenticated',
       'public.notify_unlink()', 'EXECUTE')
  then
    raise exception 'trigger functions must not be client-callable';
  end if;

  -- 3. Self-accept can never come back.
  if position('initiated_by is distinct from'
       in pg_get_functiondef('public.unlink_accept()'::regprocedure)) = 0
  then
    raise exception 'unlink_accept lost its self-accept guard';
  end if;

  -- 4. THE EXITS ARE NEVER GATED ON THE CEREMONY. Leaving can be slowed by
  --    the ceremony the leaver chose; it can never be blocked by machinery
  --    someone else controls. Mirror of the 20260826170000 assert.
  if position('couple_unlink'
       in pg_get_functiondef('public.leave_couple()'::regprocedure)) > 0
     or position('couple_unlink'
       in pg_get_functiondef('public.leave_couple_permanently()'::regprocedure)) > 0
  then
    raise exception 'the exits must never reference couple_unlink';
  end if;

  -- 5. Standing law: no force-restore names (20260826190000).
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (p.proname like '%force%restore%' or p.proname like '%restore%force%')
  ) then
    raise exception 'force-restore function names are banned';
  end if;
end $$;

-- ── ROLLBACK ─────────────────────────────────────────────────────────────
-- (Drop order matters: triggers before their functions.)
--
--   drop trigger  if exists couple_unlink_notify        on public.couple_unlink;
--   drop trigger  if exists trg_unlink_dies_with_couple on public.couples;
--   drop function if exists public.notify_unlink();
--   drop function if exists public.unlink_dies_with_couple();
--   drop function if exists public.unlink_execute();
--   drop function if exists public.unlink_write_note(bytea, bytea);
--   drop function if exists public.unlink_accept();
--   drop function if exists public.unlink_cancel();
--   drop function if exists public.unlink_start();
--   alter publication supabase_realtime drop table public.couple_unlink;
--   drop table if exists public.couple_unlink;
--
-- leave_couple / leave_couple_permanently / purge_couple were never touched,
-- so rollback restores nothing there. A ceremony already EXECUTED stays
-- executed — it went through leave_couple(), and the ordinary 30-day restore
-- window applies to it like any other dissolution. Ceremonies still in
-- flight simply vanish: nobody is unlinked by rolling back.
--
-- Second run of this file: no-op. The table is IF NOT EXISTS, every function
-- is CREATE OR REPLACE, the policy and triggers are DROP IF EXISTS first,
-- the publication add is existence-gated, and the assertions are read-only.
