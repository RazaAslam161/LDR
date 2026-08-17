# Market readiness audit — 2026-08-17

Six lenses (first-run, broken, missing, reliability, polish, trust) over build 43.
73 confirmed (7 blocker / 37 high / 27 medium), 6 refuted. 86-agent workflow, every finding adversarially verified.

# MILES — MARKET READINESS: THE ANSWER

## 1. IS IT READY FOR STRANGERS?

**Nearly. Not today. About two weeks of focused work away.**

The single reason: **when your partner sends a message, the other phone shows nothing.** No banner, no sound, no badge, no dot on the Chat tab. Ever. On any phone. That was a deliberate choice for two people who talk all day and never needed it. It does not survive one stranger. It is the #1 review a messaging app gets when it's wrong, and it will be your first review.

Three more things are also launch-stopping:

- **New users may never receive their confirmation email.** You're on Supabase's shared dev mail sender — roughly 2 messages per hour for the whole project — and there is no "resend" button anywhere. On launch day, the 3rd person to sign up in any hour simply cannot create an account. They see "check your inbox" and nothing comes.
- **The Private Vault does not work.** Pick photos, every one fails, and the app blames their connection. It only works if the user has first wandered into "Closer" — a module that ships switched off. Proven by running the code, not guessed.
- **Your database is on the free plan.** 1 GB of file storage. Your own two testers wrote 67 MB in one 9-hour day. Even discounting that tenfold, 1 GB is a few weeks of a handful of couples. When it fills, photo and video uploads fail for *everyone at once*, with a generic error.

Everything else on this list is fixable, and most of it is hours, not days.

---

## 2. WHAT MAKES A NEW USER QUIT IN THE FIRST TEN MINUTES

In order of how many people it kills:

1. **The confirmation email never arrives.** Dead before they start.
2. **The first screen is a login form saying "Welcome back."** No explanation of what Miles is, no "create account" as the main button, and a back arrow in the corner that does nothing when tapped. Looks frozen in the first five seconds.
3. **First form, blank field → "Something went wrong. Please try again."** The app knows exactly what's missing and refuses to say. Every new user hits this screen.
4. **Pairing screen with bad signal prints a raw error** naming your database hostname. Looks broken and unfinished.
5. **"I'm male" / "I'm female", no third option, no skip, no way out.** Anyone who won't pick is trapped in a loop. Guaranteed one-star.
6. **Four pop-ups land at once**, one of them asking for their password again a minute after signup. That one is indistinguishable from a scam screen — your own code comment says so.
7. **There is no way to invite your partner.** No share button. You copy a code, and the "copy link" makes `tethered://join?code=...` — dead grey text in WhatsApp that does nothing on a phone without the app. The one thing this app is *for* has no working path.
8. **Every time they switch to WhatsApp and back, the app restarts.** Blank frame, everything reloads, scroll position gone — on a build where they never chose a disguise and get nothing for the cost.
9. **They send a message. Partner never finds out.** (The blocker above.)
10. **Weak signal, and Chat says "Say something sweet — send the first message."** To a couple with months of history, the app just announced it deleted their conversation. No error, no retry.
11. **Vault: pick photos → all fail → "check your connection."** Their connection is fine.
12. **The disguise lockout.** Pick the Calculator cover and the confirmation dialog tells them the unlock gesture for a *different* cover ("tap the logo 5 times / hold the Local tab"). A calculator has no logo. They confirm, the app vanishes from the launcher, and the only instructions they were given are wrong. That's losing your account in two taps.

---

## 3. WHAT'S MISSING THAT PEOPLE JUST EXPECT

- **Notifications when a message arrives** (the code is written and unreachable)
- **Search** — no way to find anything, in chat or anywhere else
- **Chat history past 300 messages** — about two weeks. Older messages are on the server but the app has no way to reach them and no "load earlier"
- **Any record that a call happened** — no call list, no missed-call note. Face-down phone = you never know you were called
- **Change your password** (or email) from inside the app
- **A share button to invite your partner**
- **Turn off "online", "typing…", read receipts, and "In Chat"** — right now your partner sees which screen you're on, minute by minute, and there is no switch. Every competitor ships these controls precisely because couples are where they get misused
- **"Forgot PIN" on the vault** — forget four digits and your photos are gone forever. The *other* PIN screen in the same app already has full recovery
- **A way to email you.** Your support address is in the code and never shown on screen. Right now the only support channel is the review section
- **Any sign that you're offline**, and a failed message that sends itself when signal returns
- **The photo gallery where people can find it.** It's hidden inside a padlocked tab called "Closer" that's off by default. Nobody looking for "our photos" will ever find it
- **A button on the forced-update screen.** On the Play build it's a full-screen block with nothing to tap

---

## 4. WHAT'S ALREADY GOOD — STOP SPENDING TIME HERE

- **The code is genuinely clean.** 0 errors, 0 warnings, 823 tests passing, plus a self-policing test suite that checks the disguise is intact and no file is served unprotected. Unusual discipline.
- **Your error messages (in auth) are the best-written strings in the app** — typed, specific, actionable. They're the model, not the problem.
- **The security work is strong and honest.** Encryption refuses to write plaintext rather than silently downgrade. Your FAQ volunteers what is *not* encrypted, which almost no app does. Protection is on for all 63 database tables.
- **Location permission is done perfectly** — explains itself before asking, and repairs itself on Home if refused. Copy that pattern for notifications and you're done.
- **The hard Play requirements are already met**: real account deletion, in-app reporting, all four legal pages live and returning 200, child-safety contact documented.
- **No dead buttons. Zero TODOs in 51 screens.** Empty states are written everywhere. Send queue survives the phone killing the app. Reconnection logic is better than most commercial apps.
- **Play packaging is already right** — installs as itself, never side-installs.
- **Ignore Mapbox billing.** Free to 25,000 users. Not a risk.

Blunt version: the engineering craft is well above average. What's missing is the whole class of problem that only shows up when the user isn't you — bad network, refused dialog, full disk, and a stranger who doesn't know the tricks.

---

## 5. SHORTEST PATH TO READY

### MUST FIX BEFORE STRANGERS — roughly 8–10 working days

**Group A — the four blockers (~3 days + $25/mo)**
- Turn on a real email service (Resend/Postmark) + add a "resend email" button — 2 hours
- Turn message notifications on, with a Settings switch, default ON — 1 day
- Move Supabase to the Pro plan — 10 minutes, $25/month, not optional
- Derive the vault key when the vault opens, and show the real error — 4 hours

**Group B — the first ten minutes (~4 days)**
- Say what's actually wrong on the first form — 15 min
- Stop printing raw errors on the pairing screen — 10 min
- Remove the dead back arrow — 5 min
- **Show the correct unlock gesture in the disguise dialog** — 15 min (this one loses accounts)
- Add "prefer not to say" to gender, and keep a visible sign-out — half day
- Stop the four dialogs stacking; move the password prompt off first-run — 1 day
- Explain the notification request before it appears, and warn on Home if it's off — half day
- Real "Invite partner" share button with a normal https link — 1 day
- Stop the app tearing itself down on app-switch when no cover is set — 2 hours
- Chat says "couldn't connect — retry" instead of "send the first message" — 2 hours
- Fix the Closer tab spinning forever when there's no partner — 1 hour
- Move Gallery out of the padlocked tab — 2 hours

**Group C — cheap honesty fixes (~1 day, all copy)**
- "Delete account" claims to delete messages and photos. With a partner still paired it deletes neither. Fix the wording.
- "Remove partner" promises your private data is preserved. It permanently destroys the vault. Fix one or the other.
- Vault notes say "only you can ever read this" — they're stored as plain readable text. Your own FAQ already admits it.
- Location says "only your partner can ever see this" — the server can read it. Soften one sentence.
- Period tracking is shared with the partner by default. Flip it off and ask once.
- Switch on breached-password blocking in Supabase — 5 minutes, free.
- Put an "Update in Play Store" button on the forced-update screen.
- The GIF picker currently tells users to go register a developer account at giphy.com.

**Group D — one day of actually using it**
Watch Together, Memory Threads, the Vault and the Timeline have **never once been used in production, by anyone, including you.** Zero rows, all time. Run all four end to end on two phones before a stranger does.

### CAN WAIT UNTIL AFTER LAUNCH
Chat search (2–3 days) · load older messages (1–2 days — becomes urgent at ~3 weeks of use) · call history (1 day) · change password (half day) · offline banner + auto-resend (1 day) · privacy switches for online/typing/receipts (1–2 days) · forgot-PIN (1 day) · encrypt vault notes (1 day) · screen-reader labels and big-font pass (2 days) · the 15-second GPS loop draining battery (1 day) · cutting ~43 MB of unused download size (1–2 days) · the presence traffic that gets expensive around 10,000 couples (3–4 days).

---

## 6. SHOULD YOU BUY THE CONSOLE ACCOUNT NOW?

**Yes. Buy it today. But do not put a single tester on it until Group A and Group B are done.**

Why buy now:
- It's $25 once. It is not the money that's at risk.
- Account creation, identity verification, the store listing, screenshots, the data-safety form and content rating all take real calendar days and none of them require the app to be fixed. Do that paperwork while you fix the code.
- Your 14-day testing clock can't start until testers are actually in, so buying early costs you nothing and buys you the setup time for free.

Why **not** to start testing now:
- Today's build gives a tester: an account they may not be able to create, no notification when their partner writes, a vault that fails on every photo, and a "Closer" switch that spins forever if their partner hasn't joined.
- A 14-day continuous test needs people who keep opening the app. Testers who hit that list stop opening it in two days. You'd burn the goodwill of the only twelve people who'll do this for you free, and then have to ask them again.
- Fixing first costs you two weeks. Testing on this build costs you your testers.

**Do this:** buy the Console today, spend this week on Group A + B + C, spend one day on Group D actually using the app, then invite your twelve testers to a build that works. Budget $25 once for Play and $25/month for the database — that second one is required, not optional.

---

**Self-check (scores, evidence-based)**
| Criterion | Score | Basis |
|---|---|---|
| Grounded in verified findings | 9 | Every claim traces to a confirmed, adversarially-verified finding; refuted items excluded |
| Plain language, no jargon | 9 | No "E2EE"/"RLS"/"SMTP"; blockers stated as user-visible events |
| Ordering reflects real quit-risk | 8 | Ranked by reach (email → first screen → first form), not by severity label |
| Answers all six questions | 9 | Each section present and distinct |
| Blunt, no hedging | 9 | Verdict is "not today"; the notification choice is named as a mistake |
| Actionable with effort figures | 8 | Every item carries an effort estimate from the audits |

**DECIDE: FINAL.** No criterion below 8.

*Rule collision, named out loud: the global instruction to open with a visible self-prompt block conflicts with the explicit request for "no report he has to decode." Deliverable format won; the scored loop is kept, moved to the bottom. Nothing was edited or committed — audit only.*