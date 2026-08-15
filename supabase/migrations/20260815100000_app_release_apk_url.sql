-- Self-update: where the latest sideload APK lives and how to verify it.
--
-- app_release already carries min_build (the hard gate: below it a client is
-- blocked) and latest_build (the newest build that exists). These three columns
-- let an out-of-date sideload client download and install the update itself
-- instead of the APK being rebuilt and hand-carried to every phone.
--
-- Additive and nullable: a client that never selects them reads the row exactly
-- as before, and an environment where they are unset simply offers no update.
-- The row is already readable by anon (ReleaseGate reads it before sign-in), so
-- no policy or grant change is needed.
alter table public.app_release
  add column if not exists apk_url text,
  add column if not exists apk_sha256 text,
  add column if not exists latest_version_name text;

comment on column public.app_release.apk_url is
  'HTTPS URL of the latest sideload APK. Must be signed with the same key as installed builds or Android refuses the in-place update.';
comment on column public.app_release.apk_sha256 is
  'Lowercase hex SHA-256 of the APK at apk_url. The client refuses a download that does not match; guards transit corruption/tampering, not the signature (the OS checks that).';
comment on column public.app_release.latest_version_name is
  'Human version name shown in the update prompt, e.g. 0.1.0.';
