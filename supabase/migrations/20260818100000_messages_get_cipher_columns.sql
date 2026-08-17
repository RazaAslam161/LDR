-- Chat E2EE, step 1 of a sequence: the columns only. Inert until a client
-- writes them, and safe for every already-installed client.
--
-- public.messages.body is TEXT and holds cleartext (93 of 97 prod rows). Every
-- other feature in this app stores a bytea cipher+nonce PAIR — vault_items,
-- fantasy_jar_entries, memory_threads — so chat is the outlier, not the pattern.
-- These two columns give it the same shape:
--
--   body_nonce  = the 24-byte XChaCha20 nonce
--   body_cipher = mac(16) || ciphertext,  packMacAndCiphertext()
--                 (closer_crypto.dart:55 — NOT nonce||mac||ct, that is packFull,
--                  and NOT ct||mac, which is wish_jar's incompatible layout.
--                  Naming it here because the repo contains both and picking
--                  the wrong one is undetectable until decryption fails.)
--
-- WHY WRITES ARE NOT SWITCHED ON IN THIS MIGRATION. Nothing on the chat path
-- ever derives the couple key: `ensureSharedKey`/`deriveSharedKey` is called
-- from Closer, the wish jar, memory threads and the rewrap screen and from
-- nowhere else, `_sharedKey` is in-memory and is cleared by bindAccount on
-- every cold start, and `couples.modest_mode` DEFAULTS TO TRUE while
-- closer_screen.dart:45 skips key prep entirely when it is on. So a new couple
-- has no published key and no derived key, and CryptoCore.encryptBytes throws
-- rather than writing cleartext (crypto_core.dart:655). Encrypting sendText
-- before fixing that would make every text send fail for every couple that has
-- not opened Closer — which is all of them by default. The existing test couple
-- has modest_mode off and both keys published, which is exactly why this breaks
-- for new users and not on the two handsets.
--
-- The CHECK is a PAIR check, deliberately not a "cipher is required" check.
-- A required-cipher constraint would 23514 on every insert from an
-- already-installed client, and chat_repository._alreadyLanded only forgives
-- 23505 — so those sends would become permanent red bubbles, and for media the
-- file is uploaded before the insert, so each rejection would orphan a storage
-- object too. messages has no column-level ACLs (attacl null on every column;
-- relacl is table-level), so adding columns needs no grant and old clients are
-- unaffected by their existence.
--
-- Second run: no-op (add column if not exists, drop constraint if exists).
--
-- Reverse with:
--   alter table public.messages drop constraint if exists messages_body_cipher_pair;
--   alter table public.messages drop column if exists body_cipher;
--   alter table public.messages drop column if exists body_nonce;

alter table public.messages add column if not exists body_cipher bytea;
alter table public.messages add column if not exists body_nonce  bytea;

alter table public.messages drop constraint if exists messages_body_cipher_pair;
alter table public.messages add constraint messages_body_cipher_pair
  check ((body_cipher is null) = (body_nonce is null));

comment on column public.messages.body_cipher is
  'mac(16) || XChaCha20-Poly1305 ciphertext of the message text. Pairs with '
  'body_nonce. Written by clients that have a derived couple key; body stays '
  'populated alongside it during the dual-write era. The plaintext body read '
  'fallback is PERMANENT, not transitional: the release gate fails open, so a '
  'client below min_build can always still write a plaintext-only row.';
comment on column public.messages.body_nonce is
  '24-byte XChaCha20 nonce for body_cipher. An all-zero nonce means the value '
  'is NOT encrypted (CryptoCore plaintext-v1 sentinel) and must be refused on '
  'write, never stored as if it were ciphertext.';
