# Miles — Privacy Policy

**Last updated: 17 August 2026**

Miles is a private app for two people in a relationship. This policy says what
it stores, what it cannot read, who else touches your data, how long any of it
survives, and how to get rid of it. It is written to be accurate rather than
reassuring — where something is *not* protected, this document says so.

Miles is published by **RD Developers**, Sector C Commercial Area, Bahria Town, Lahore, Pakistan. Privacy questions and data requests:
**milesapp.officials@gmail.com**.

---

## 1. What Miles collects

**Your account.** An email address and a password, held by our authentication
provider. A display name, an optional profile photo, your time zone, your date
of birth, and — if you set them — a gender, a status message, your usual wake
and sleep times, and your chat theme and chat background image. The date of
birth is used twice: sign-up refuses anyone who enters a date under 18 years
ago, and the Closer and Touch features are hidden from any account whose stored
date of birth is under 18. It is the date you type; Miles does not verify it
against any document.

**Your pairing.** Miles only works in twos. When you pair, both accounts are
linked to a shared couple record. Invite codes and failed pairing attempts are
recorded so codes cannot be guessed.

**What you send each other.** Chat messages, photographs, videos, voice notes
and documents. Items you add to the shared gallery, with their captions. Time
capsules and what you put inside them. Scheduled rituals, visits, prompts,
check-ins, the shared routine chart, reasons you love each other, and Watch
Together sessions.

**What you record in Closer.** Closer is the intimacy area of the app. It holds
Memory Threads (titles, notes, places and photographs), Wish Jar entries and
their category tags, Pick For Us dice rolls, warmth scores, body-map touches,
and intimacy signals. Section 2 says exactly which of these the server can read
and which it cannot — they are not all the same.

**Health data.** The cycle tracker is off until you switch it on. Once on, it
stores your logged period dates, cycle events, and your average cycle and period
lengths. **It is shared with your partner by default** — there is a switch on
the cycle screen to stop that, but it starts on. Cycle data is not end-to-end
encrypted; see section 2.

**Where you are, if you turn it on.** Location sharing is per-account and has
three modes: off, city (only a "City, Country" label leaves your phone — never
coordinates), or precise (coordinates plus a finer label). A new account starts
at **off**, and nothing is shared until the feature is switched on.

Be clear about how it gets switched on, because it is not a second tap. Miles
shows you a dialog explaining the feature, and if you then grant Android's
location permission, Miles treats that grant as your choice and turns sharing
on: **precise** if you gave precise access, city if you gave only approximate.
That happens once per account on a given handset; after that the mode is only
ever what you set. You can move it to city or back to off in Settings at any
time, and either takes effect on the next update.

While sharing is on, your position updates about every 15 seconds and only while
the app is open and in the foreground. Miles requests no background-location
permission and runs no background location service. Turning sharing off writes
empty coordinates and an empty place label over the stored ones.

The Time Capsule "when you're together" unlock is separate and stores nothing:
both phones broadcast a coarse position over a transient realtime channel, each
device computes the distance itself, and no coordinate is ever written to the
database.

**Presence.** While the app is open it writes an "online / last seen"
heartbeat, which screen you are on, whether you are typing, when you last read
the chat, and — if you set them — your current mood, its colour, a status
activity, an avatar emoji and a check-in photo. This is what lets your partner
see that you are there.

**A push token.** A Firebase Cloud Messaging registration token for your device,
so your partner's messages and calls can reach you.

**Crash reports.** One narrow stream, and the only diagnostic Miles still
sends. A crash uploads your account id, the app's build number, the exception's
**type**, a machine-readable code (an SQLSTATE, an auth error code, an errno)
and the Dart stack frames — at most five a run. The exception's **message is
discarded on your device before anything is sent**, precisely because a message
like `no key for <your message text>` is how private content escapes an
encrypted app. This stream is genuinely write-only: no client key can read a
crash report back, including your own.

Miles used to also upload a behavioural event trace — calls, receipts, presence,
app lifecycle. **It was retired and no current build records anything into it.**
The table it wrote to still exists, is empty, and is still swept on a schedule;
unlike crash reports, an account could read back its own rows there if there
were any.

**Safety and account records.** If you file a report — the route is set out in
the Terms — Miles stores who filed it, the reason you chose, what kind of thing
you reported, an optional note you write, the build number, and, unless you are
reporting the app itself, your partner's account id, which the server fills in
from your pairing rather than accepting it from your phone. It stores no copy of
the reported content. Miles also records that you accepted a given version of
the Terms and when, and any notification or contact pause you set against your
partner.

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
| Memory Threads | titles, notes, partner notes, places and photographs |
| Wish Jar | the text of each entry |

**NOT end-to-end encrypted — stored so that the server *could* read them:**

| | |
|---|---|
| Chat | message text, photos, videos, voice notes, documents |
| Shared gallery | the images and videos, and their captions |
| Time capsules | contents and attachments |
| Personal Vault | everything in it — the files and thumbnails you save, the text of notes, and the label on every item. Only you can reach the Vault, not even your partner, and it is additionally guarded by its PIN and by a block on screenshots — but it is not end-to-end encrypted |
| Closer, apart from the two rows above | dice rolls and their tags, warmth scores, body-map touches and their positions, intimacy signals |
| Location | coordinates and place labels |
| Cycle tracker | logs, events and settings |
| Presence | online state, last seen, current screen, typing, mood, check-in photo |
| Profile | name, photo, time zone, date of birth, gender, status, wake and sleep times |
| Rituals, visits, prompts, check-ins, routine chart, reasons | contents |
| Reports and Terms acceptances | contents, as described in section 1 |

These are protected by database row-level security and private storage buckets —
only you and your partner can fetch them through the app — and by encryption in
transit and at rest at the hosting provider. They are **not** protected from the
operator of the database. Do not treat chat as if it were end-to-end
encrypted.

**Four further limits, stated because they are true:**

1. **Encryption covers the contents, not the shape.** A Memory Thread's title
   and photographs are ciphertext, but the date you dated it to, how many
   photographs it holds, when it was created and who proposed it are stored in
   the clear. The server cannot read your memories; it can see that you have
   them, and when.
2. **Wish Jar categories are effectively readable.** Entry text is encrypted,
   but each entry carries a tag hash used so both phones can match categories.
   That hash is an unkeyed 32-bit FNV-1a over a fixed twelve-item list, so
   anyone with database access can compute all twelve and reverse it. The
   *category* of an entry is not private from the operator; the words are.
3. **Some old rows are plain text.** Encryption was introduced after the app
   already had data. Rows written before it — and rows written while one
   partner was still on an older build — are stored unencrypted and are
   recognisable as such. They are readable by anyone with database access.
4. **Calls.** Voice and video are peer-to-peer and encrypted in transit
   (DTLS-SRTP). When a direct connection cannot be made, the encrypted stream is
   relayed through Cloudflare, which sees the relayed packets and both devices'
   IP addresses but not the contents.

---

## 3. Your encryption key, and what recovery costs

Your private key lives only on your phone. Android erases it when the app is
uninstalled, which would make everything encrypted permanently unreadable — so
Miles keeps a **sealed** copy on the server.

The seal is derived from your account password: the password is put through
Argon2id (memory-hard, deliberately slow) with a random salt, and the resulting
key wraps your private key with XChaCha20-Poly1305. The server holds the wrapped
blob, the salt, a nonce and the derivation parameters, and can derive nothing
from them alone. Seals written before Argon2id was introduced used a fast key
derivation instead; those are re-sealed the first time they are opened.

Two honest consequences:

- **Your password is the whole of that protection.** The same password is sent
  to the authentication service every time you sign in, and the key that opens
  the seal is derived from that exact string — the two secrets are one secret.
  Anyone who obtains your password, or who captures it at that endpoint, can
  open the sealed key and decrypt everything it protects. The seal defends
  against a stolen database backup, not against a stolen password.
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
| **Google — Firebase Cloud Messaging** | your device's push token, and per notification: a type word (`reach`, `care`, `call`, `message`, `memory`, `ritual`), your couple's id, the id of the row that triggered it, and for a call whether it is a video call | Delivering notifications. **No names, no message text, no photographs, and no location pass through Google.** The notification you see is composed on your own phone from those identifiers. |
| **Cloudflare** | the encrypted media stream and both devices' IP addresses, only when a direct connection fails | TURN relay for voice and video calls. |
| **Mapbox** | map tile requests, which reveal the area of the map you are looking at, and your IP address | Drawing the world map. |
| **Google — Maps SDK** | map tile requests for the area being drawn, and your IP address | The map that shows where your partner is. Only reached from the location screens. |
| **Google — Android geocoder** | the coordinates your phone turns into a place name | Turning a fix into the "City, Country" label. This is Android's own geocoder, which on a device with Google services is answered by Google. |
| **Google — ML Kit** | nothing leaves the device | Pose detection and subject cut-out for Touch Map photo reactions. The models run on your phone; the photograph is not uploaded to Google. |
| **Giphy** | your GIF search terms, your IP address, and a request for each GIF shown | The GIF picker in chat. Only when you open it. |
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
- **Photos and videos** — on Android 13 and later Miles asks only for the
  specific items you select, through the system photo picker or the document
  picker, and never for broad access to your gallery. On Android 12 and earlier,
  which have no per-item grant, Miles declares the old read-external-storage
  permission; on those versions granting it does give the app read access to
  shared storage. Nothing in Miles scans or indexes your gallery on any version.
- **Files** — choosing a document to send in chat, through the system file
  picker.
- **Location (approximate and precise)** — only for the sharing feature and the
  "when you're together" unlock, both described in section 1. **Foreground
  only.** Miles does not request background location.
- **Notifications** — messages, calls and reaches.
- **Bluetooth** — choosing a headset for call audio.
- **Biometrics** — the fingerprint or face prompt that opens the app lock and
  the Memory Threads gate. The check happens on your phone; Miles never receives
  the biometric itself.
- **Screen capture** — only if you start a screen share during a call, and
  Android asks you each time. Miles cannot capture your screen outside a call
  you are in.

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
| Retired trace table | 2 days, and capped by row count — nothing is written to it any more |
| Crash reports | 14 days, and capped by row count |
| Deleted memory threads | erased 30 days after deletion |
| Unanswered joint delete requests | the requester can force them through after 14 days |
| Reports you file | kept with no expiry, so that a pattern of abuse can be acted on. Deleting your account deletes the reports you filed; a report filed *about* you outlives your account, with your account id removed from it |
| Terms acceptances, call-relay credential requests | kept with no expiry |
| **A relationship either of you ends** | removing your partner — or deleting your own account — dissolves the couple **for both of you at once**; it does not wait for the second person to act. The couple's entire history — messages, photographs, videos, Closer content — is **deleted 30 days after that**. Inside those 30 days the deletion can still be cancelled, but only by both of you: one asks to reconnect and the other agrees — neither can do it alone. Pairing again with a fresh code does not cancel it; that is a new couple, and these records are still deleted on schedule. |

Two honest notes on files. Deleting your account queues every file you and your
partner stored for real deletion, and a job runs hourly to carry it out — if
that job is unable to run, the queue waits rather than dropping, so "usually
within the hour" is the expectation and not a guarantee.

The other paths — clearing a message or a whole conversation for both of you,
and the 30-day purge after a relationship ends — remove the database record of
the file rather than passing it to the storage service for deletion. The
practical effect is that nothing and nobody can reach the file again: no link
can be issued for it and it appears in no listing. The underlying bytes,
however, remain in the hosting provider's storage, unreferenced, rather than
being erased. If you want the bytes themselves gone, use Delete my account, or
write to us and ask.

---

## 7. Your rights, and how to actually use them

**See your data.** Almost everything Miles holds about you is visible in the
app, on the screen that produced it. Four things are not, on purpose: crash
reports, delivery failures for notifications sent to you, call-relay credential
requests, and reports — including reports you filed yourself. Reports are
unreadable from every client key, because a screen listing "reports you have
filed about your partner", on a phone that partner may pick up, is the most
dangerous thing this app could draw. For a copy of any of it, including the
hidden four, write to milesapp.officials@gmail.com.

**Correct it.** Profile, name, photo, time zone and every preference are
editable in Settings.

**Delete individual things.** Messages, memories, gallery items, vault items
and cycle entries each delete from their own screen. What that costs the other
person differs by feature, and it is worth knowing which is which:

- *Both of you must agree* for Memory Threads and the shared gallery. One of you
  asks, the other confirms, and only then is it destroyed. If your partner
  neither confirms nor refuses, you can force it through after 14 days.
- *Either of you can act alone* in chat. You can delete your own message for
  both of you, and **either partner can clear the entire conversation — every
  message and every file in it — for both of you, with no confirmation from the
  other.** There is no undo and no copy kept.
- *Only you* can touch your Personal Vault and your cycle entries.

**Delete your account.** Two routes, both real:
- *In the app*: Settings → Delete my account.
- *On the web, without reinstalling*: [Delete your Miles account](../../web/delete-account.html),
  published beside this policy as `delete-account.html`. You enter your email,
  receive a code at that address, and confirm. We never delete an account on an
  unverified request.

What deletion does: your account and profile are erased, your Personal Vault
and its files are erased, and you are unlinked from your couple. Your crash
reports, your escrowed key, your Terms acceptances and the reports you filed go
with the account. If your partner has already left, the couple's entire history
and every file the two of you stored are deleted with it. If your partner is
still there, their copy of the conversation you shared remains theirs — the same
conversation is their data too — and it is deleted under the 30-day rule when
they leave or delete in turn. One thing survives: a report your partner filed
about you, kept without your account id attached to it.

**Withdraw consent.** Turn off location sharing, revoke any permission in
Android settings, or stop using a feature. None of it is retroactive: turning
sharing off erases the stored position, but does not unsend what your partner
already saw.

**Object or complain.** Write to milesapp.officials@gmail.com. If you are in the
UK, EEA or another jurisdiction with a data-protection authority, you may
complain to it directly.

---

## 8. Children

Miles is for adults. You must be 18 or older to create an account: sign-up asks
for your date of birth and refuses a date under 18 years ago, and the Closer and
Touch features check the stored date again before they will appear. Both checks
are made against the date you typed — Miles does not verify it against any
document — so they are a gate, not proof. If we learn that an account belongs to
someone under 18 we delete it.

Our standards against child sexual abuse and exploitation, and how to report it,
are set out in full in [Child Safety Standards](../../web/csae.html), published
beside this policy as `csae.html`.

---

## 9. Where your data is

Data is stored and processed in the **ap-south-1 (Mumbai, India)** region.
Notification delivery (Google), call relaying (Cloudflare) and map tiles
(Mapbox) route through those providers' global infrastructure, which may be
outside your country.

---

## 10. Security, and what it does not cover

Data is encrypted in transit (TLS) and at rest, files live in private buckets
reachable only through short-lived signed links, access is enforced per-row so
that only you and your partner can reach your couple's data, and the surfaces
listed in section 2 are end-to-end encrypted on top of that. **Chat is not one
of them** — read section 2 rather than assuming this one covers it.

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

RD Developers
Sector C Commercial Area, Bahria Town
Lahore, Pakistan
milesapp.officials@gmail.com
