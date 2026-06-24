-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — Settings (Issue 7) + Message delete (Issue 1D/1E). After schema.sql.
-- ───────────────────────────────────────────────────────────────────────────
alter table public.profiles add column if not exists status_message text;
alter table public.couples  add column if not exists active boolean not null default true;

-- Unlink both partners (couple dissolves, data preserved on the inactive couple).
create or replace function public.leave_couple()
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;
  update public.profiles set couple_id = null where couple_id = v_couple;
  update public.couples  set active = false   where id = v_couple;
end; $$;
revoke execute on function public.leave_couple() from public, anon;
grant  execute on function public.leave_couple() to authenticated;

-- ── Message soft-delete ─────────────────────────────────────────────────────
alter table public.messages add column if not exists deleted_for_sender   boolean not null default false;
alter table public.messages add column if not exists deleted_for_everyone boolean not null default false;
alter table public.messages add column if not exists deleted_at           timestamptz;
-- Correct per-user "delete for me" model (the single boolean above can't hide a
-- received message for the receiver):
alter table public.messages add column if not exists deleted_by uuid[] not null default '{}';

drop policy if exists "messages_update_member" on public.messages;
create policy "messages_update_member" on public.messages
  for update using (couple_id = public.current_user_couple_id())
  with check (couple_id = public.current_user_couple_id());
alter table public.messages replica identity full;

create or replace function public.hide_message(p_message_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.messages
     set deleted_by = (select array(select distinct unnest(deleted_by || auth.uid())))
   where id = p_message_id and couple_id = public.current_user_couple_id();
$$;
revoke execute on function public.hide_message(uuid) from public, anon;
grant  execute on function public.hide_message(uuid) to authenticated;

create or replace function public.delete_message_for_everyone(p_message_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.messages set deleted_for_everyone = true, deleted_at = now()
   where id = p_message_id and sender_id = auth.uid();
$$;
revoke execute on function public.delete_message_for_everyone(uuid) from public, anon;
grant  execute on function public.delete_message_for_everyone(uuid) to authenticated;

create or replace function public.clear_conversation()
returns void language sql security definer set search_path = public as $$
  update public.messages
     set deleted_by = (select array(select distinct unnest(deleted_by || auth.uid())))
   where couple_id = public.current_user_couple_id();
$$;
revoke execute on function public.clear_conversation() from public, anon;
grant  execute on function public.clear_conversation() to authenticated;
