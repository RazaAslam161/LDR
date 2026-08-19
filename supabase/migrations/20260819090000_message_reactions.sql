-- Emoji reactions on chat messages.
--
-- ADDITIVE ONLY. A new table beside `messages`; not one column is added to it,
-- renamed, or retyped. Every APK already in the field keeps reading `messages`
-- exactly as it does today and simply never selects this table — which is the
-- whole requirement on a sideloaded fleet with no update channel.
--
-- ROLLBACK, written and proven before the forward change was applied:
--     drop table if exists public.message_reactions;
-- `drop table` also removes the table from `supabase_realtime`, so the
-- publication needs no separate undo.
--
-- ORDER MATTERS, and it did not when this line was first written.
-- 20260819100000 has since made `delete_message_for_everyone` — a SECURITY
-- DEFINER function every installed APK calls — reference this table. A
-- PL/pgSQL body is not a tracked dependency, so the drop succeeds silently and
-- the next "delete for everyone" raises 42P01, taking the body scrub down with
-- it in the same transaction. Restore that function to its 20260818160000
-- definition (written out in full in 20260819100000's own header) FIRST, then
-- drop this table.
--
-- A SECOND RUN IS A NO-OP. Every statement is `if not exists` or is preceded
-- by `drop ... if exists`, and the publication add is guarded on
-- pg_publication_tables — `alter publication ... add table` is the one
-- statement here that errors on a repeat.
--
-- NO NOTIFICATION CAN COME OF THIS. The only push trigger in the schema is
-- `message_notify_on_insert AFTER INSERT ON public.messages`. Reactions never
-- touch `messages`, so a reaction cannot post a covers notification — which a
-- disguised build could not do safely in any case.

create table if not exists public.message_reactions (
  message_id   uuid        not null references public.messages(id) on delete cascade,
  user_id      uuid        not null references auth.users(id)      on delete cascade,
  -- Denormalised so RLS is the same single comparison every other couple-scoped
  -- table here uses, instead of a join to `messages` on every row read. The
  -- INSERT policy below is what keeps it honest.
  couple_id    uuid        not null references public.couples(id)  on delete cascade,
  -- mac || ciphertext, and its nonce, exactly as `messages.body_cipher` and
  -- `vault_items` store theirs. The emoji IS content — it records what one
  -- partner felt about one message — and this app keeps no plaintext at rest.
  -- There is deliberately no plaintext column beside it: bodies need one only
  -- because shipped clients read `body`, and no shipped client has ever read
  -- this table.
  emoji_cipher bytea       not null,
  emoji_nonce  bytea       not null,
  created_at   timestamptz not null default now(),
  -- Last-writer-wins ordering for the live wire. Two devices can disagree about
  -- the order of a fast add/remove/add; this is what settles it.
  updated_at   timestamptz not null default now(),
  -- ONE reaction per person per message. Changing your mind is an UPDATE of
  -- this row, never a second row, so "remove mine" is unambiguous and a count
  -- can never exceed the two people in the couple.
  primary key (message_id, user_id)
);

-- The PK's leading column already serves lookups by message. These two exist
-- for the FKs: an unindexed FK makes every couple deletion and every account
-- deletion a sequential scan of this table.
create index if not exists message_reactions_couple_idx
  on public.message_reactions (couple_id, updated_at desc);
create index if not exists message_reactions_user_idx
  on public.message_reactions (user_id);

alter table public.message_reactions enable row level security;

-- Read: couple members only, the same comparison `messages_select_member` and
-- `chat_receipts_select_member` make. `(select ...)` so the STABLE function is
-- evaluated once per statement rather than once per row (initplan) — the same
-- shape 20260815071213 moved every other policy to.
drop policy if exists message_reactions_select_member on public.message_reactions;
create policy message_reactions_select_member on public.message_reactions
  for select using (couple_id = (select public.current_user_couple_id()));

-- Write: your own reaction, in your own couple, on a message that is actually
-- in that couple. The last clause is why the denormalised couple_id cannot be
-- forged into someone else's conversation.
--
-- The message reference is qualified on BOTH sides on purpose. An unqualified
-- `couple_id` inside the subquery would bind to `m.couple_id` and the check
-- would compare the row to itself — a tautology that silently passes anything.
drop policy if exists message_reactions_insert_own on public.message_reactions;
create policy message_reactions_insert_own on public.message_reactions
  for insert with check (
    user_id = (select auth.uid())
    and couple_id = (select public.current_user_couple_id())
    and exists (
      select 1 from public.messages m
      where m.id = public.message_reactions.message_id
        and m.couple_id = (select public.current_user_couple_id())
        -- And not one that is already gone. 20260819100000 makes the delete
        -- RPC scrub a message's reactions, but that is a single moment: an
        -- offline client whose outbox retries minutes later would put the
        -- ciphertext straight back onto a message whose body has been erased,
        -- and `on delete cascade` never fires because the row is flagged
        -- rather than deleted. The refusal is a 42501, which the client's
        -- outbox already classifies as permanent and stops retrying.
        and not m.deleted_for_everyone
    )
  );

-- Changing your mind. USING and WITH CHECK are identical so a row cannot be
-- updated out of your own hands or out of your own couple.
drop policy if exists message_reactions_update_own on public.message_reactions;
create policy message_reactions_update_own on public.message_reactions
  for update
  using (user_id = (select auth.uid())
         and couple_id = (select public.current_user_couple_id()))
  with check (user_id = (select auth.uid())
              and couple_id = (select public.current_user_couple_id()));

-- Taking it back. Yours only: a partner cannot remove your reaction, the same
-- way they cannot delete your message.
drop policy if exists message_reactions_delete_own on public.message_reactions;
create policy message_reactions_delete_own on public.message_reactions
  for delete using (user_id = (select auth.uid())
                    and couple_id = (select public.current_user_couple_id()));

-- Table privileges, stated here rather than inherited.
--
-- A new table takes whatever `pg_default_acl` mints, and the two projects do
-- not agree: production's default was narrowed by 20260601007010, staging's was
-- not. Created without these lines, this table came out on staging with
-- `anon` and `authenticated` both holding TRUNCATE — and TRUNCATE does not
-- consult a single one of the four policies above. The anon key ships inside
-- the APK, so that is one request from anybody to empty every couple's
-- reactions. A grant a migration does not state is a grant nobody owns.
revoke all on public.message_reactions from anon;
revoke truncate, references, trigger on public.message_reactions
  from authenticated, anon;
grant select, insert, update, delete on public.message_reactions to authenticated;

-- The live backstop behind the broadcast fast path. Broadcast is at-most-once:
-- when it is dropped, this is what still moves the partner's screen without a
-- reopen.
--
-- FULL, not the default primary key. A removal arrives as a DELETE, and under
-- the default replica identity the old row carries only (message_id, user_id)
-- — so a client filtered on couple_id would never see a single removal.
alter table public.message_reactions replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'message_reactions'
  ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end $$;
