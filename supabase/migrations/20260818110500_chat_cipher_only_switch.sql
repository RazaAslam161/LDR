-- Chat E2EE step 3, the switch only. Additive, defaults OFF, changes nothing
-- until an operator deliberately flips it.
--
-- Step 3 is "stop writing messages.body in the clear". That cannot be a code
-- release, because the moment one client writes cipher-only, every client that
-- has not yet updated renders a blank bubble — and this app has no forced
-- update channel and a release gate that FAILS OPEN, so no build number proves
-- the old ones are gone. It has to be a server-side decision made after the
-- fleet is observed to be ready, and reversible in one statement if it is not.
--
-- Preconditions the operator must satisfy BEFORE setting this true. None of
-- them are enforceable here, so they are written down here instead:
--   1. A build containing the dual-write (ReleaseGate.buildNumber >= 46) is
--      published AND installed. As of this migration prod app_release says
--      latest_build = 45, so no field build can read ciphertext at all.
--   2. min_build has been raised past that build for the SIDELOAD channel and
--      those clients have taken the self-update.
--   3. min_build_play is handled SEPARATELY and LAST. It is 0 today, the Play
--      build has no self-updater, and raising it locks Play users out of a
--      disguised couples app until Google's staged rollout reaches them.
--   4. The msg_insert_result diag shows `sealed: true` across the fleet. A low
--      rate means clients are writing plaintext-only rows; flipping then makes
--      those messages unreadable to everyone including their author.
--
-- What the client does with it: when true AND the body actually sealed, the
-- insert omits `body`. When the body did NOT seal — no couple key, a rewrap in
-- flight, a pin mismatch — the client writes plaintext REGARDLESS of this flag.
-- A message with no readable text anywhere is worse than a message the server
-- can read, and that rule lives in the client so this switch can never cause it.
--
-- Known consequence, accepted: messages.media_class is a STORED generated
-- column whose 'link' arm reads body (20260601005500). With body null a text
-- message classifies NULL, so the Links shelf stops indexing new links. The
-- 'media' and 'file' arms read `kind` and are unaffected. Links inside a
-- conversation still render — chat_screen runs LinkScan over the DECRYPTED
-- text — so what is lost is the server-side shelf, not the feature. Preserving
-- the shelf would mean the client telling the server "this message contains a
-- URL" on every send, which is a per-message metadata leak to the one party
-- this app exists to keep out. The shelf loses; prod has 0 rows with
-- media_class='link' and has never had one, so nothing is being taken away.
--
-- Second run: no-op (add column if not exists).
--
-- Reverse with:
--   alter table public.app_release drop column if exists chat_cipher_only;
-- Or, to undo a flip without dropping the column:
--   update public.app_release set chat_cipher_only = false;

alter table public.app_release
  add column if not exists chat_cipher_only boolean not null default false;

comment on column public.app_release.chat_cipher_only is
  'When true, clients stop writing messages.body in the clear and rely on '
  'body_cipher. Flip ONLY after a dual-write build is installed across both '
  'channels — an older client renders a cipher-only row as a blank bubble and '
  'the release gate fails open. Clients ignore this and write plaintext anyway '
  'whenever the body did not seal, so it can never produce a textless message.';
