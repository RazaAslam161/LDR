# Sideload self-update — how to ship an update without the Play Store

The sideload build updates itself. Publish one APK at a fixed URL and flip a row
in `app_release`; every phone downloads and installs it the next time it opens.
No more rebuild-and-hand-transfer to each device.

This is the `sideload` channel only. The `play` channel updates through the
Play Store and the self-updater is compiled out of it (a Play app that installs
its own APK is a policy strike).

---

## Bootstrap: the first build cannot update itself

A build can only self-update if it already contains the updater. Build 28 and
everything before it does not, so the feature cannot install itself onto them.

- **Once**: build the first version that contains the updater and install it on
  each phone by hand — the last transfer you will ever do.
- **After that**: every later build is a `release.sh` run plus one row.

Publishing an APK to `app_release` before any phone runs a build that carries
the updater is harmless but does nothing: older builds never read `apk_url`.

---

## The one rule that makes or breaks it: same signing key

Android only updates an APK **in place** when the new one is signed with the
**same key** as the installed one. A different key installs as a *new* app and
the old one's `flutter_secure_storage` (the E2EE private key) is lost.

- **Do this before your first hosted update:** create a real release keystore,
  sign every sideload build with it, and back it up in two places. See
  `PLAY-RELEASE-RUNBOOK.md` for the `keytool` command. Until then you are on the
  per-machine debug key — updates work **only** if you always build on the same
  PC and never wipe `~/.android/debug.keystore`.
- The SHA-256 the client checks guards transit corruption/tampering, **not** the
  signature. The OS enforces the signature; a mismatch shows "App not installed".

---

## Where to host it — not Supabase Storage

**Supabase Storage cannot hold this APK on the free plan.** Verified: the free
tier caps uploads at **50 MB per file** and the APK is ~220 MB. (The project's
largest bucket limit is 100 MB and its largest object ever is 33 MB, so nothing
in the project contradicts the cap.) The upload simply fails.

**Use Cloudflare R2**, and keep using it after any Supabase upgrade. APK hosting
is almost pure egress, and that is exactly what R2 does not charge for:

| | free storage | egress | max object |
|---|---|---|---|
| **Cloudflare R2** | 10 GB | **$0** | 5 TB |
| Supabase free | 1 GB (520 MB already used) | 5 GB/mo | **50 MB — too small** |
| Supabase Pro | 100 GB | 250 GB/mo included | 500 GB |

One release to 1,000 phones is ~220 GB of egress. That is a rounding error on R2
and the entire monthly Pro allowance on Supabase.

Do **not** use a public GitHub release — the asset and repo would be public and
this is a couples-intimacy app. The APK URL itself being public is fine: the
security model already assumes the APK is readable by anyone (all secrets live
server-side behind RLS). Just don't put couple data in the filename.

### Uploading without an API token

The R2 dashboard uploads objects directly: bucket → **Objects** → **Upload** →
drag the APK in. R2's single-PUT ceiling is 5 GiB, so a ~220 MB APK is nowhere
near a limit. Name the object exactly `news.apk` so the stored `apk_url` keeps
working.

That is the whole upload. The API token below only exists to make it scriptable;
for an occasional release, dragging the file in is a legitimate permanent answer.

### One-time R2 setup (only needed for scripted uploads)

No CLI to install: the release script uploads with **curl's built-in SigV4**
(`--aws-sigv4`), so `curl` is the only tool involved. No aws-cli, no rclone.

1. Cloudflare dashboard → **R2** → *Create bucket*, name it e.g. `miles-releases`.
2. Bucket → **Settings** → *Public access* → enable **r2.dev**. Note the public
   base URL. (r2.dev is rate-limited and Cloudflare says not to lean on it for
   production — fine for a few phones; attach a custom domain if the fleet grows.)
3. **R2 → Manage API Tokens** → create a token with *Object Read & Write*, scoped
   to that bucket. Copy the **Access Key ID** and **Secret Access Key** once —
   the secret is shown only at creation.
4. Note your **Account ID** (R2 sidebar). The S3 endpoint is
   `https://<account-id>.r2.cloudflarestorage.com`.
5. Put these in your shell — never in the repo. Add them to `~/.bashrc` so a
   release is genuinely one command:
   ```bash
   export MILES_R2_ACCOUNT_ID=<account id>
   export MILES_R2_BUCKET=miles-releases
   export MILES_R2_KEY=<access key id>
   export MILES_R2_SECRET=<secret access key>
   export MILES_APK_URL=https://pub-c97f0d4f49074dc3b7bdfe01521b7745.r2.dev/Miles.apk
   ```
   Optional: `MILES_R2_OBJECT` to rename the object (default `news.apk`).

---

## Credentials: tool/.release-env

Copy `tool/.release-env.example` to `tool/.release-env` and fill it in. That file
is gitignored and `release.sh` sources it automatically.

Use the file rather than `~/.bashrc`: a **non-interactive** shell — an agent, a
cron job, anything not a terminal — never sources `~/.bashrc`, so exports kept
there are invisible to it and `--ship` stops at the first missing variable.
Verified: the agent shell reports flags `hBc` (no `i`) with `BASH_ENV` unset.
Anything already exported in the environment still wins.

---

## Every release: one command

```bash
cd /e/LDR/mobile && bash tool/release.sh --ship
```

`--ship` = bump + build + upload + verify + publish. Use
`--upload --verify --publish` to ship without bumping, or no flags to build and
hash only.

What it does, in order:

- **Refuses to build** when `pubspec.yaml`'s `+N` and `ReleaseGate.buildNumber`
  disagree. They have drifted before — a versionCode-27 APK once reported itself
  as 26, and raising `min_build` then locks out the very build it was meant to
  admit. Missing env vars are also checked here, *before* the ten-minute build.
- Builds the **sideload** flavour and prints the SHA-256 and size.
- `--upload` overwrites the object in R2 (curl SigV4, `-f` so an HTTP error is a
  failure rather than an error page silently written over your release).
- `--verify` re-downloads the **public URL** and compares the hash to the build.
  This is the check that prevents a fleet-brick: a blocked phone's only way back
  is that URL, so if it serves truncated, stale, or wrong bytes, every gated
  phone loops forever. It costs a full download — run it before raising
  `min_build`, always.
- Prints the SQL below, filled in.

Run it with no flags to build and hash only.

### The four steps it automates

1. **Bump the build** — `pubspec.yaml` `version: 0.1.0+N` **and**
   `lib/core/app/release_gate.dart` `buildNumber = N`. `versionCode` must
   increase or Android will not treat it as an update. (This one is still
   manual; the script only verifies it.)
2. **Build** `flutter build apk --release --flavor sideload`. The flavour is
   mandatory — a bare release build enters the play graph and stops on the
   missing upload key, deliberately.
3. **Upload**, overwriting the *same* object so the URL never changes.
4. **Publish** — one row, `id = true`:
   ```sql
   update public.app_release set
     latest_build        = N,
     latest_version_name = '0.1.0',
     apk_url             = 'https://<your-r2-public-url>/news.apk',
     apk_sha256          = '<sha from step 3>'
   where id = true;
   ```
   That is the whole deployment. Phones on an older build now offer the update.

---

## Optional vs mandatory

- **Optional** (`min_build <= installed < latest_build`): a dismissible prompt
  once per launch, a row in Settings, and — if the user ignores both — nothing
  breaks. This is the default; only `latest_build` moved.
- **Mandatory** (`installed < min_build`): the app stops at the block screen with
  an **Update now** button. Raise `min_build` only for a change an old client
  genuinely cannot survive (a schema it can't read), and only **after** the
  tolerating build is actually in the field — see the three-step protocol in
  `release_gate.dart`. Setting `min_build = N` locks out every build below N, so
  the self-update button is their only way back.

  **Verify the hosted APK before you raise `min_build`.** A blocked client's only
  escape is downloading `apk_url` and having it install. If that APK is corrupt,
  its `apk_sha256` is wrong, or it is signed with a different key than the
  installed build, every gated phone loops on a failed install with no other way
  out. Install the exact hosted APK over a real device on the previous build
  first, confirm it updates in place, and only then raise `min_build`.

---

## First-run on each phone (one time)

The system asks the user to allow "install unknown apps" for this app the first
time it installs an update; the in-app prompt sends them to that setting and
they tap Update again. Nothing to pre-configure.

---

## Rollback

Point `apk_url`/`apk_sha256`/`latest_build` back at the previous APK and hash.
Because `latest_build` drives the "newer exists" check, lowering it makes clients
stop offering the update; they will not downgrade themselves.
