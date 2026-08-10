-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the two holes no linter reports.
--
-- 1. REALTIME BROADCAST WAS UNAUTHENTICATED.
--
-- Every topic in this app is named after a couple: messages:<id>, call:<id>,
-- mood_burst:<id>, body_touches:<id>, and seventeen more. All 29 were PUBLIC
-- channels, and a public channel authorises nothing. RLS protects the messages
-- TABLE; it never sees the broadcast that carries the same body as a fast path
-- (chat_screen sends 'body' over mood_burst so the partner sees it instantly).
--
-- So the anon key — which ships inside the APK and can be unzipped out of it —
-- plus one couple UUID was enough to sit on that couple's live chat in
-- plaintext, along with their typing, touch coordinates, presence and WebRTC
-- signalling. The UUID is not guessable, but it never needed to be: it was in
-- every storage URL until this week, and an ex-partner who has been through
-- leave_couple() still knows it, because leaving does not rotate it. That is
-- the case that makes this worth closing rather than rating unlikely.
--
-- These policies authorise a private channel only for a member of the couple it
-- is named for. Every topic embeds that id somewhere — sometimes last
-- (messages:<id>), sometimes not (gcard:<deck>:<id>) — so the match is on
-- containment rather than a fixed segment.
--
-- ORDER: policies first, client second. Policies without private channels
-- change nothing; private channels without policies would deny every
-- subscription in the app at once.
create policy realtime_couple_topics_read on realtime.messages
  for select to authenticated
  using (
    realtime.topic() like '%' || (select public.current_user_couple_id())::text || '%'
  );

create policy realtime_couple_topics_write on realtime.messages
  for insert to authenticated
  with check (
    realtime.topic() like '%' || (select public.current_user_couple_id())::text || '%'
  );

-- 2. EVERY BUCKET ACCEPTED ANY FILE, AT ANY SIZE.
--
-- file_size_limit and allowed_mime_types were NULL on all four. Any signed-in
-- account could upload a 5GB file, or an APK, or anything else it wanted hosted
-- behind someone else's domain. On a project billed for storage and egress that
-- is the cheapest way to run up a bill, and it needs no exploit — just an
-- account.
--
-- Sized from what is actually stored: couple_media averages 324KB across 255
-- objects, couple_intimate 3.4MB across 16 because it holds video.
update storage.buckets set
  file_size_limit = 26214400,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif',
                             'audio/mp4','audio/aac','audio/mpeg','audio/ogg']
where id = 'couple_media';

update storage.buckets set
  file_size_limit = 104857600,
  allowed_mime_types = array['image/jpeg','image/png','image/webp',
                             'video/mp4','video/quicktime',
                             'audio/mp4','audio/aac','audio/mpeg']
where id = 'couple_intimate';

update storage.buckets set
  file_size_limit = 52428800,
  allowed_mime_types = array['image/jpeg','image/png','image/webp',
                             'video/mp4','audio/mp4','audio/aac','audio/mpeg']
where id = 'capsule-media';

-- chat-bg holds zero objects and nothing reads a public URL from it, so unlike
-- couple_media it could close immediately rather than waiting on a build.
update storage.buckets set
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg','image/png','image/webp']
where id = 'chat-bg';
