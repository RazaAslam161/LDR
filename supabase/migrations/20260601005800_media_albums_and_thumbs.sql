-- ───────────────────────────────────────────────────────────────────────────
-- Miles — "it should be like whatsapp media mechanism": twenty photos picked
-- at once are ONE bubble with a grid in it, not twenty full-width bubbles down
-- a mile of column, and the tiles paint from thumbnails rather than from the
-- originals.
--
-- Two columns, for the two halves of that.
--
-- ALBUM_ID — which send a row belongs to
--
-- Grouping could be inferred client-side from (sender, kind, a few seconds of
-- created_at) and in fact it HAS to be, for two reasons that are not going
-- away: every row already in the table predates this column, and this fleet is
-- sideloaded with no update channel, so builds that have never heard of
-- album_id keep sending one-photo-per-row for as long as they stay installed.
-- The client therefore falls back to the time window whenever this is null.
--
-- But the window is a guess, and it is wrong exactly where it costs most: a
-- pick of eleven photos and one 90-second video uploads over a minute, so the
-- video lands far outside any window tight enough not to swallow the next
-- unrelated message. Stamping the group at the picker — one uuid for one pick,
-- decided before a byte moves — makes new sends exact and leaves the heuristic
-- to cover only what it must.
--
-- Deliberately NOT indexed. Nothing looks a row up by album; grouping happens
-- over a page of messages the client already holds, and the album a row is in
-- is only ever read from that row. An index here would be write cost on the
-- hottest table in the app for a query that is never made.
--
-- HAS_THUMB — whether a small sibling object exists
--
-- Every bucket is private, so a tile cannot simply try the thumbnail and fall
-- back on 404: the miss costs a signature and a round trip, per tile, on every
-- row written before today. This says up front which of the two paths to sign.
--
-- The thumbnail is a sibling of the original under a `thumb/` segment —
-- `<couple>/img_x.jpg` becomes `<couple>/thumb/img_x.jpg` — so the couple id
-- stays the FIRST path segment and the existing storage policies
-- (foldername(name))[1] = couple_id continue to cover it with no new policy.
--
-- Both columns are nullable/defaulted and additive: an old build selects * ,
-- ignores what it does not know, and is unaffected.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.messages
  add column if not exists album_id uuid;

alter table public.messages
  add column if not exists has_thumb boolean not null default false;

comment on column public.messages.album_id is
  'One uuid per multi-select send. Null for single sends and for any row '
  'written by a build older than this column — the client groups those by a '
  '(sender, kind, time window) heuristic instead.';

comment on column public.messages.has_thumb is
  'A thumbnail exists at the same path under a thumb/ segment. False on every '
  'row predating the pipeline; those render from the original.';
