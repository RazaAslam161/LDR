-- Fifth instance of the same fault, and the first one nobody had noticed.
--
-- afterglow_screen.dart has a full request → confirm delete flow — buttons at
-- :513 and :520, handlers at :357/:377/:385, three repository methods at
-- :839/:847/:858 — writing six columns that have never existed on
-- afterglow_entries. Verified against information_schema: the live table is
-- exactly id, couple_id, happened_at, gratitude_a, nonce_a, photo_a,
-- gratitude_b, nonce_b, photo_b, retention, sealed_at, created_at.
--
-- Two failure modes, and the quiet one is worse:
--
--   Writes throw PGRST204 — the same signature as the memory_threads and
--   rituals bug 006600 fixed. Loud, at least.
--
--   Reads fail SILENTLY. fetchEntries and streamEntries both select *, so the
--   server raises nothing; json['delete_requested'] is simply absent and
--   defaults to false. streamEntries:672 `if (row['deleted'] == true) continue;`
--   therefore tests a key that is always null, which means the delete filter in
--   this feature has never filtered anything. Unlike rituals — where the
--   .neq('deleted', true) filter blew up and got fixed — this one degrades
--   without a symptom until someone notices deletion does not work.
--
-- 006600 fixed exactly this for memory_threads and rituals and named afterglow
-- in its own header comment as a prior instance, then did not add afterglow's
-- columns.
--
-- Types mirror vault_items and rituals verbatim, which are the working
-- precedent. The two uuid columns reference profiles ON DELETE SET NULL rather
-- than auth.users NO ACTION — 007000 has just spent a migration undoing that
-- exact choice on two other tables, and repeating it here would re-break
-- delete_my_account the moment somebody used the feature.
alter table public.afterglow_entries
  add column if not exists delete_requested    boolean not null default false,
  add column if not exists delete_requested_by uuid references public.profiles(id) on delete set null,
  add column if not exists delete_requested_at timestamptz,
  add column if not exists deleted             boolean not null default false,
  add column if not exists deleted_by          uuid references public.profiles(id) on delete set null,
  add column if not exists deleted_at          timestamptz;

-- The list query is "this couple's entries, newest first, not deleted".
create index if not exists afterglow_entries_live_idx
  on public.afterglow_entries (couple_id, happened_at desc) where not deleted;

do $do$
declare missing text;
begin
  select string_agg(c, ', ') into missing from unnest(array[
    'delete_requested','delete_requested_by','delete_requested_at',
    'deleted','deleted_by','deleted_at']) c
   where not exists (select 1 from information_schema.columns
                      where table_schema='public' and table_name='afterglow_entries'
                        and column_name = c);
  if missing is not null then
    raise exception 'afterglow_entries still missing: %', missing;
  end if;
end $do$;
