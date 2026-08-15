# Miles — Privacy Policy

**Last updated: 15 August 2026**

> **BEFORE PUBLISHING — fill these three placeholders and delete this block.**
> `R&D Dev` · `Pakistan` · `Razaaslam3210@gmail.com`
> They also appear in `web/privacy-policy.html`, which is the copy users read.
> `https://sopictusdonlvuezmfep.supabase.co/functions/v1/delete-account` is wherever you host `web/delete-account.html`.

Miles is a private app for two people in a relationship. This policy says what
it stores, what it cannot read, who else touches your data, how long any of it
survives, and how to get rid of it. It is written to be accurate rather than
reassuring — where something is *not* protected, this document says so.

Miles is published by **R&D Dev**, Pakistan. Privacy
questions and data requests: **Razaaslam3210@gmail.com**.

---

## 1. What Miles collects

**Your account.** An email address and a password, held by our authentication
provider. A display name, an optional profile photo, your time zone, and your
date of birth. The date of birth is used for one thing: the intimacy features
are refused to anyone under 18.

**Your pairing.** Miles only works in twos. When you pair, both accounts are
linked to a shared couple record. Invite codes and failed pairing attempts are
recorded so codes cannot be guessed.

**What you send each other.** Chat messages, photographs, videos, voice notes
and documents. Anything you write or capture inside the intimacy module
("Closer") — memory threads, private-vault items, fantasy-jar entries.
Scheduled rituals, visits, prompts and check-ins.

**Health and intimacy data.** If you use the cycle tracker, its logs and
settings. If you use Closer, the categories and content of what you record
there. This is sensitive data and it is treated as such below.

**Where you are, if you turn it on.** Location sharing is **off by default**
and is per-account. You choose one of three modes: off, city (only a
"City, Country" label leaves your phone — never coordinates), or precise
(coordinates plus a finer label). It updates only while the app is open and in
the foreground. Miles requests no background-location permission and runs no
background location service. Turning sharing off erases the last position from
the server.

The Time Capsule "when you're together" unlock is separate and stores nothing:
both phones broadcast a coarse position over a transient realtime channel, each
device computes the distance itself, and no coordinate is ever written to the
database.

**Presence.** While the app is open it writes an "online / last seen" heartbeat
and which screen you are on, so your partner sees when you are there.

**A push token.** A Firebase Cloud Messaging registration token for your device,
so your partner's messages and calls can reach you.

**Diagnostics.** Two narrow streams, both write-only from the app's point of
view — no client can read them back.
- *Traces*: call, delivery-receipt, presence and app-lifecycle events (event
  name, sequence, timing, your account and couple id).
- *Crash reports*: the exception's **type**, a machine-readable code (an
  SQLSTATE, an auth error code, an errno) and the Dart stack frames. The
  exception's **message is discarded on your device before anything is sent**,
  precisely because a message like `no key for <your message text>` is how
  private content escapes an encrypted app.

Miles contains no advertising SDK, no analytics SDK, and no third-party
tracking. Nothing here is sold, and nothing here is used to build an
advertising profile.

---

## 2. What is end-to-end encrypted — and what is not

This matters more than any other section, so it is stated plainly.

Each phone holds an X25519 private key in the platform keystore. The two phones
agree a shared key (ECDH + HKDF) and encrypt with XChaCha20-Poly1305. Where
that applies, the server stores ciphertext it cannot open.

**End-to-end encrypted — the server cannot read these:**

| | |
|---|---|
| Memory Threads | titles, notes and photographs |
| Private Vault (inside Closer) | notes, photos, video and audio |
| Fantasy Jar | the text of each entry |

**NOT end-to-end encrypted — stored so that the server *could* read them:**

| | |
|---|---|
| Chat | message text, photos, videos, voice notes, documents |
| Personal Vault (the owner-only vault, not the Closer one) | note text is stored as plain text |
| Location | coordinates and place labels |
| Cycle tracker | logs, events and settings |
| Presence | online state, last seen, current screen |
| Profile | name, photo, time zone, date of birth |
| Rituals, visits, prompts, check-ins | contents |

These are protected by database row-level security and private storage buckets —
only you and your partner can fetch them through the app — and by encryption in
transit and at rest at the hosting provider. They are **not** protected from the
operator of the database. Do not treat chat as if it were the vault.

**Three further limits, stated because they are true:**

1. **Fantasy Jar categories are effectively readable.** Entry text is encrypted,
   but each entry carries a tag hash used so both phones can match categories.
   That hash is an unkeyed 32-bit FNV-1a over a fixed twelve-item list, so
   anyone with database access can compute all twelve and reverse it. The
   *category* of an entry is not private from the operator; the words are.
2. **Some old rows are plain text.** Encryption was introduced after the app
   already had data. Rows written before it — and rows written while one
   partner was still on an older build — are stored unencrypted and are
   recognisable as such. They are readable by anyone with database access.
3. **Calls.** Voice and video are peer-to-peer and encrypted in transit
   (DTLS-SRTP). When a direct connection cannot be made, the encrypted stream is
   relayed through Cloudflare, which sees the relayed packets and both devices'
   IP addresses but not the contents.

---

## 3. Your encryption key, and what recovery costs

Your private key lives only on your phone. Android erases it when the app is
uninstalled, which would make everything encrypted permanently unreadable — so
Miles keeps a **sealed** copy on the server.

The seal is derived from your account password: the password is put through a
labelled HMAC and then Argon2id (memory-hard, deliberately slow), and the
resulting key wraps your private key with XChaCha20-Poly1305. The server holds
the wrapped blob, a salt and a nonce, and can derive nothing from them alone.

Two honest consequences:

- **Your password is the whole of that protection.** The same password is sent
  to the authentication service every time you sign in. Anyone who obtains your
  password — or who compromises that endpoint — can open the sealed key and
  decrypt everything it protects. The seal defends against a stolen database
  backup, not against a stolen password.
- **If you forget your password, the seal cannot be opened either.** Resetting a
  password restores access to your *account*, not to content encrypted under a
  key you can no longer unwrap. Miles also offers a partner-assisted recovery,
  where your partner's phone hands your history's keys back to your new device.
  If neither route works, that content is gone. Nobody — including us — can
  recover it.

---

## 4. Who else receives data

| Who | What they get | Why |
|---|---|---|
| **Supabase** | everything in section 1 that is stored at all | Hosting: database, file storage, authentication, realtime and server functions. Data is held in the **ap-south-1 (Mumbai, India)** region. |
| **Google — Firebase Cloud Messaging** | your device's push token, and per notification: a type word (`reach`, `care`, `call`, `message`, `memory`, `ritual`), your couple's id, and the id of the row that triggered it | Delivering notifications. **No names, no message text, no photographs, and no location pass through Google.** The notification you see is composed on your own phone from those identifiers. |
| **Cloudflare** | the encrypted media stream and both devices' IP addresses, only when a direct connection fails | TURN relay for voice and video calls. |
| **Mapbox** | map tile requests, which reveal the area of the map you are looking at, and your IP address | Drawing the map. |
| **Google — Maps SDK & platform geocoder** | for the Touch Map, map requests; for the "City, Country" label, the coordinates your phone turns into a place name | Map display and reverse geocoding. |
| **Giphy** | your GIF search terms | The GIF picker in chat. Only when you open it. |
| **YouTube and other video sites** | ordinary web requests from the embedded player | Watch Together, only for a link you paste. |
| **Google Fonts** | a font request on first launch | Typefaces. |

We do not sell personal data and we do not share it for advertising.

We disclose data to anyone else only where we are legally compelled to. We
cannot disclose what we cannot read.

---

## 5. Permissions the app asks for

Miles asks for each of these at the moment the feature needs it, and every one
can be refused or withdrawn in Android's app settings.

- **Camera** — taking photos and video in chat, capsules and Closer; video calls.
- **Microphone** — voice notes and voice/video calls.
- **Photos and videos** — Miles uses Android's system photo picker, so it asks
  only for the specific items you select. It does not request broad access to
  your gallery and cannot browse it.
- **Location (approximate and precise)** — only for the sharing feature and the
  "when you're together" unlock, both described in section 1. **Foreground
  only.** Miles does not request background location.
- **Notifications** — messages, calls and reaches.
- **Bluetooth** — choosing a headset for call audio.

---

## 6. How long things are kept

| Data | Kept for |
|---|---|
| Account, profile, chat, Closer content, cycle data | until you delete them or delete your account |
| Live "reach" alerts | 30 seconds (the alert); 30 days (the record) |
| Care nudges | 30 days |
| Touch / body-map signals | 7 days |
| Call invitations | 2 days |
| Call signalling | 1 day |
| Very short-lived presence pulses | 1 hour to 1 day |
| Failed pairing attempts | 1 day |
| Diagnostic traces | 2 days, and capped by row count |
| Crash reports | 14 days |
| Deleted memory threads | erased 30 days after deletion |
| Unanswered joint delete requests | expire after 14 days |
| **A relationship you both leave** | the couple's entire history — messages, photographs, videos, Closer content — is **deleted 30 days after the last partner leaves**, including the files in storage. Re-pairing inside those 30 days cancels the deletion. |

Deleted files are removed from storage by a job that runs hourly, so a file is
usually gone within the hour and always within a day of the row that referenced
it.

---

## 7. Your rights, and how to actually use them

**See your data.** Everything Miles holds about you is visible in the app, on
the screen that produced it. For a copy in another form, write to
Razaaslam3210@gmail.com.

**Correct it.** Profile, name, photo, time zone and every preference are
editable in Settings.

**Delete individual things.** Messages, memories, vault items and cycle entries
each delete from their own screen. Content shared with your partner needs both
of you to agree before it is destroyed, which is deliberate — one person cannot
erase a shared history alone.

**Delete your account.** Two routes, both real:
- *In the app*: Settings → Delete my account.
- *On the web, without reinstalling*: **https://sopictusdonlvuezmfep.supabase.co/functions/v1/delete-account**. You enter your email,
  receive a code at that address, and confirm. We never delete an account on an
  unverified request.

What deletion does: your account and profile are erased, and you are unlinked
from your couple. If your partner has already left, the couple's entire
history and every file the two of you stored are deleted with it. If your
partner is still there, their copy of the conversation you shared remains
theirs — the same conversation is their data too — and it is deleted under the
30-day rule when they leave or delete in turn.

**Withdraw consent.** Turn off location sharing, revoke any permission in
Android settings, or stop using a feature. None of it is retroactive: turning
sharing off erases the stored position, but does not unsend what your partner
already saw.

**Object or complain.** Write to Razaaslam3210@gmail.com. If you are in the
UK, EEA or another jurisdiction with a data-protection authority, you may
complain to it directly.

---

## 8. Children

Miles is for adults. You must be 18 or older to create an account, and the
intimacy features check your date of birth independently. If we learn that an
account belongs to someone under 18 we delete it.

---

## 9. Where your data is

Data is stored and processed in the **ap-south-1 (Mumbai, India)** region.
Notification delivery (Google), call relaying (Cloudflare) and map tiles
(Mapbox) route through those providers' global infrastructure, which may be
outside your country.

---

## 10. Security, and what it does not cover

Data is encrypted in transit (TLS) and at rest, access is enforced per-row so
that only you and your partner can reach your couple's data, and the most
sensitive surfaces are end-to-end encrypted as described in section 2.

Three things that no amount of server-side security addresses, and that you
should weigh:

- **The person you paired with can see everything you send them.** That is the
  product. Miles cannot make a partner forget, and it cannot take back what has
  been shown.
- **A phone is the weakest link.** Miles offers an app lock and a vault PIN;
  neither survives someone who has your unlocked phone.
- **We cannot recover an encrypted history whose key is lost.** See section 3.

---

## 11. Changes

If this policy changes materially we will update the version at the hosted URL
and change the date at the top. Continued use after a change means the updated
policy applies.

---

## 12. Contact

R&D Dev
Pakistan
Razaaslam3210@gmail.com
