-- ───────────────────────────────────────────────────────────────────────────
-- Miles — "click on name to see profile of the partner and can see every
-- document, files media we shared with each other."
--
-- The profile screen draws three lists off one table: photos+videos, documents,
-- and links. Every one of them is "the newest N of a kind, then the N before
-- those" over a table that only ever grows. The existing indexes cannot serve
-- that: messages_couple_seq_idx is (couple_id, seq), so filtering by kind is a
-- filter applied AFTER the scan. A couple with 40,000 messages and 300 photos
-- would read tens of thousands of heap rows to fill one 30-tile grid, and read
-- them again for every page after the first. That is invisible on the two
-- phones this was built on, where the whole conversation fits in one page.
--
-- WHY A GENERATED COLUMN AND NOT AN INDEX ON `kind`
--
-- The Media tab wants image OR video, which as `kind = any(...)` is a
-- ScalarArrayOp on a middle index column: Postgres can use the index but not
-- always in order, so it lands a Sort on top and the LIMIT stops bounding the
-- work. Links are worse — they are not a kind at all, they are a substring of
-- body. Classifying server-side turns all three tabs into the one shape a btree
-- is perfect at: equality on the leading columns, range on the last, no sort.
--
-- It is computed by Postgres, not by the client, which matters here more than
-- usual: this fleet is sideloaded and has no update channel, so the majority of
-- installs for the next while will be builds that have never heard of this
-- column. Their messages get classified correctly anyway.
--
-- ADD COLUMN ... STORED rewrites the table. public.messages is 75 rows and
-- 496kB today; the same statement against the couple this feature is designed
-- for is a very different event. It goes in now, while it is free.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.messages
  add column if not exists media_class text
  generated always as (
    case
      when kind in ('image', 'video') then 'media'
      when kind = 'file'              then 'file'
      -- Deliberately the same test the client's regex makes, spelled the only
      -- other way it can be: `https?://` is exactly "contains http:// or
      -- contains https://". They have to agree, because a row this excludes
      -- can never be paged back in, and a row it includes that the client then
      -- finds no URL in is a blank line in the list.
      when body ilike '%http://%' or body ilike '%https://%' then 'link'
    end
  ) stored;

-- Partial so the index holds only the rows the three tabs can ever return —
-- text messages are the bulk of any conversation and none of them are in here.
-- `media_class = 'media'` is a strict operator against a constant, which
-- implies `media_class is not null`, so the planner matches the predicate
-- without the query having to restate it.
--
-- seq desc to match the read order: newest first, cursor walking backwards.
create index if not exists messages_couple_class_seq_idx
  on public.messages (couple_id, media_class, seq desc)
  where media_class is not null;

analyze public.messages;
