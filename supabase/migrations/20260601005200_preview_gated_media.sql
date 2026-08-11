-- ───────────────────────────────────────────────────────────────────────────
-- Miles — a snap arrives as "tap to view", not as the photo itself.
--
-- A column rather than a new `kind`: the media is still an image or a video,
-- still lives at image_path/video_path, and is still opened by the same viewer.
-- Every branch in the client switches on `kind` — previewText(), mediaPaths,
-- the save actions, the broadcast fast path, the cleanup job's path columns —
-- so a fifth kind would mean teaching each of them that 'snap' is really an
-- image, and any one that was missed would silently drop the media. What
-- actually differs is one bit of presentation, so one boolean carries it.
--
-- Default false, so every row already in the table keeps rendering inline —
-- the gate applies to captures taken from here on, not retroactively.
-- ───────────────────────────────────────────────────────────────────────────
alter table public.messages
  add column if not exists preview_gated boolean not null default false;

comment on column public.messages.preview_gated is
  'true when the media was captured in-app and must arrive hidden behind a '
  'tap-to-view placeholder. The message itself persists either way.';
