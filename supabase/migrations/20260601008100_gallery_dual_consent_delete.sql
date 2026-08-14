-- Deleting from the shared gallery takes both of them.
--
-- 008000 let either partner set `deleted` directly, on the reasoning that a
-- shared roll behaves like the phone's own gallery. That is wrong for THIS
-- product: the whole point of the room is that neither person can unilaterally
-- erase what the two of them put in it, and a picture is not recoverable from a
-- disagreement afterwards. So the column grant goes and the transition becomes
-- a request the other person answers — the same shape memory_threads already
-- uses, for the same reason.
--
-- Batch by construction. The request is a multi-select ("these eleven"), so a
-- per-row RPC would be eleven round trips and eleven chances to half-apply.
-- uuid[] in, one statement, all-or-nothing.

alter table public.gallery_items
  add column if not exists delete_requested    boolean not null default false,
  add column if not exists delete_requested_by uuid references public.profiles(id) on delete set null,
  add column if not exists delete_requested_at timestamptz;

-- The client may still write a caption. It may no longer write the lifecycle:
-- with `deleted` grantable, "your partner must agree" was one PATCH away from
-- being untrue.
revoke update on public.gallery_items from authenticated;
grant update (caption) on public.gallery_items to authenticated;

create index if not exists gallery_items_pending_idx
  on public.gallery_items (couple_id) where delete_requested and not deleted;

-- ── Ask ────────────────────────────────────────────────────────────────────
create or replace function public.gallery_request_delete(p_ids uuid[])
returns int language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  update public.gallery_items
     set delete_requested = true,
         delete_requested_by = auth.uid(),
         delete_requested_at = now()
   where id = any(p_ids)
     and couple_id = (select public.current_user_couple_id())
     and not deleted
     and not delete_requested;
  get diagnostics n = row_count;
  return n;
end $fn$;

-- ── Either partner calls it off ────────────────────────────────────────────
-- Including the person who asked: changing your mind must not need permission.
create or replace function public.gallery_cancel_delete(p_ids uuid[])
returns int language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  update public.gallery_items
     set delete_requested = false,
         delete_requested_by = null,
         delete_requested_at = null
   where id = any(p_ids)
     and couple_id = (select public.current_user_couple_id())
     and delete_requested and not deleted;
  get diagnostics n = row_count;
  return n;
end $fn$;

-- ── The other one agrees ───────────────────────────────────────────────────
-- `delete_requested_by is distinct from auth.uid()` is the entire guarantee,
-- and it is the reason this cannot live in the client. Soft delete only: the
-- row keeps its paths so the reaper can erase the objects through the Storage
-- API, and 007500 explains at length why removing the row first strands the
-- bytes forever.
create or replace function public.gallery_confirm_delete(p_ids uuid[])
returns int language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  update public.gallery_items
     set deleted = true, deleted_at = now(), deleted_by = auth.uid(),
         delete_requested = false
   where id = any(p_ids)
     and couple_id = (select public.current_user_couple_id())
     and delete_requested and not deleted
     and delete_requested_by is distinct from auth.uid();
  get diagnostics n = row_count;
  return n;
end $fn$;

do $do$ declare f text; begin
  foreach f in array array['gallery_request_delete(uuid[])',
                           'gallery_cancel_delete(uuid[])',
                           'gallery_confirm_delete(uuid[])']
  loop
    execute format('revoke all on function public.%s from public, anon;', f);
    execute format('grant execute on function public.%s to authenticated;', f);
  end loop;
end $do$;

do $do$
begin
  if has_table_privilege('authenticated','public.gallery_items','DELETE') then
    raise exception 'gallery_items must stay soft-delete only';
  end if;
  if has_column_privilege('authenticated','public.gallery_items','deleted','UPDATE') then
    raise exception 'the client can still set deleted directly; consent is bypassable';
  end if;
end $do$;
