-- ───────────────────────────────────────────────────────────────────────────
-- Miles — stop storing public URLs for objects that are about to be private.
--
-- couple_media was a PUBLIC bucket holding 255 of a couple's photos. Its RLS
-- was correct and the bucket was never listable, so this was not enumeration —
-- it was that `/object/public/...` needs no authentication at all. Any URL that
-- ever escaped (a forwarded link, a screenshot, a proxy log, browser history)
-- was readable by anyone, permanently, with no way to revoke it. The app
-- already signed couple_intimate correctly; this half had simply never been
-- brought over.
--
-- The client now stores a storage PATH and signs at read time. These rows
-- predate that. MediaUrls.toPath handles either shape so nothing breaks in the
-- meantime, but a database that keeps handing out a link which stops working
-- the moment the bucket closes is a bug waiting for a support question.
--
-- ORDER MATTERS, and the bucket flip is deliberately NOT in this file:
--   1. this migration            (safe while the bucket is still public)
--   2. ship the APK that signs
--   3. install it on BOTH phones
--   4. only then set couple_media and chat-bg to private
-- Flipping first would turn every photo in the installed app into a broken
-- image, because the build in people's hands still asks for the public URL.
-- ───────────────────────────────────────────────────────────────────────────

update public.presence
   set checkin_photo_url =
         split_part(checkin_photo_url, '/object/public/couple_media/', 2)
 where checkin_photo_url like '%/object/public/couple_media/%';

update public.profiles
   set avatar_url = split_part(avatar_url, '/object/public/couple_media/', 2)
 where avatar_url like '%/object/public/couple_media/%';
