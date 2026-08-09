-- ───────────────────────────────────────────────────────────────────────────
-- Miles — read receipts, rebuilt. Idempotent; safe to re-run. No data deleted.
--
-- WHY THIS IS A REPLACEMENT AND NOT A FIX
--
-- The old model compared two different clocks. `presence.chat_last_read` was
-- stamped by the READER'S PHONE; `messages.created_at` by POSTGRES. "Seen"
-- was `chat_last_read > created_at - 1s`. That is only a watermark if both
-- sides come from the same clock, and they never were:
--
--   * reader's phone slow by 40s -> messages stay on a black double tick for
--     40s after being read, and the last message before they close the chat
--     never turns green at all
--   * reader's phone fast -> messages are marked seen that were never on
--     screen, and the client latches it permanently
--
-- Two NTP-synced dev phones agree to the millisecond, which is exactly why
-- this looked correct for two months and failed for everyone else.
--
-- The fix is to delete the clock from the problem. Ordering comes from a
-- server-assigned monotonic integer, and advancement is `greatest()` inside a
-- SECURITY DEFINER function, so a receipt cannot move backwards no matter what
-- any device believes the time is.
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1. A server-assigned order that no device can influence ────────────────
-- created_at stays, for display only. It is never used for receipt logic again.
alter table public.messages add column if not exists seq bigint;

create sequence if not exists public.messages_seq_seq owned by public.messages.seq;
alter table public.messages alter column seq set default nextval('public.messages_seq_seq');

-- Backfill in created_at order so existing history keeps its ordering.
do $$
begin
  if exists (select 1 from public.messages where seq is null) then
    with ordered as (
      select id, row_number() over (order by created_at, id) as rn
        from public.messages where seq is null
    )
    update public.messages m set seq = o.rn from ordered o where m.id = o.id;
    perform setval('public.messages_seq_seq',
                   coalesce((select max(seq) from public.messages), 0) + 1,
                   false);
  end if;
end $$;

alter table public.messages alter column seq set not null;
create index if not exists messages_couple_seq_idx on public.messages(couple_id, seq);

-- ── 2. Receipts live in their own table, not in ephemeral presence ─────────
-- presence is "what is true right now" and is rewritten constantly. A durable
-- fact ("she has read up to here") does not belong in it: the old code had to
-- move the watermark BACKWARDS to express "she left the chat", which un-read
-- every message she had already read.
create table if not exists public.chat_receipts (
  couple_id     uuid not null references public.couples(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  -- Highest seq this user's device has RECEIVED (delivered), and READ.
  -- delivered >= read is not enforced; ack_read advances both.
  delivered_seq bigint not null default 0,
  read_seq      bigint not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (couple_id, user_id)
);

alter table public.chat_receipts enable row level security;

-- Both partners must READ each other's receipts (that is the whole point),
-- but nobody may write anyone's row directly — advancement goes through the
-- RPCs below so monotonicity is enforced server-side and cannot be bypassed
-- by a PATCH.
drop policy if exists "chat_receipts_select_member" on public.chat_receipts;
create policy "chat_receipts_select_member" on public.chat_receipts
  for select using (couple_id = public.current_user_couple_id());

-- ── 3. Advancement is the ONLY operation, and it is monotonic by construction ─
create or replace function public.ack_delivered(p_seq bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;
  insert into public.chat_receipts (couple_id, user_id, delivered_seq)
  values (v_couple, v_uid, greatest(p_seq, 0))
  on conflict (couple_id, user_id) do update
    -- greatest() is the invariant. A late, out-of-order, or replayed ack can
    -- never un-deliver anything.
    set delivered_seq = greatest(public.chat_receipts.delivered_seq, excluded.delivered_seq),
        updated_at = now();
end; $$;

create or replace function public.ack_read(p_seq bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;
  -- Reading implies delivery: you cannot read what you never received.
  insert into public.chat_receipts (couple_id, user_id, delivered_seq, read_seq)
  values (v_couple, v_uid, greatest(p_seq, 0), greatest(p_seq, 0))
  on conflict (couple_id, user_id) do update
    set read_seq      = greatest(public.chat_receipts.read_seq, excluded.read_seq),
        delivered_seq = greatest(public.chat_receipts.delivered_seq, excluded.delivered_seq),
        updated_at = now();
end; $$;

revoke execute on function public.ack_delivered(bigint) from public, anon;
revoke execute on function public.ack_read(bigint)      from public, anon;
grant  execute on function public.ack_delivered(bigint) to authenticated;
grant  execute on function public.ack_read(bigint)      to authenticated;

-- ── 4. Receipts must arrive live, or the sender's tick never updates ───────
alter table public.chat_receipts replica identity full;
do $$
begin
  begin
    alter publication supabase_realtime add table public.chat_receipts;
  exception when duplicate_object then null;
  end;
end $$;

-- Seed a row for everyone already paired, so a partner who never opens the
-- chat still has a row to render against instead of a missing one.
insert into public.chat_receipts (couple_id, user_id)
select couple_id, id from public.profiles where couple_id is not null
on conflict (couple_id, user_id) do nothing;
