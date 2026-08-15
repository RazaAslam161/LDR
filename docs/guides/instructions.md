# All standing instructions from Raza

Compiled 2026-08-15; last updated 2026-08-15 (mythos-run additions).
**The live source is `~/.claude/CLAUDE.md`** — loaded into every Claude Code session, every project, every model, every message. This file is a readable snapshot of it plus the verbatim quotes behind each rule.
When a repo doc and these instructions disagree, the instructions win — a doc records what was true when written; these record what he wants now.

---

## A. Global working agreement (current `~/.claude/CLAUDE.md`)

### Mythos-peak intelligence, every message *(added 2026-08-15)*
- Operate at maximum depth on every message, every project — the deepest reasoning available, never the quick shallow pass ("mythos peaked intelligence").
- Substantive tasks get full orchestration: multi-agent fan-out, adversarial verification of findings, synthesis — not a single-pass answer.
- Depth never excuses drift from these rules: verification, minimal footprint, and bullets-not-paragraphs still bind.
- (This file cannot switch the model itself — that is the `/model` setting; this rule governs how hard the selected model works.)

### Verification — non-negotiable
- YOU MUST NOT report a task as done without pasting the actual command you ran and its actual output. No output shown = not done.
- If a claim can be checked (tests pass, build succeeds, coverage is X%), check it before stating it. If it can't be checked mechanically, label it "unverified" explicitly — don't present opinion as fact.
- If no tests exist for a change, say so as a flagged gap. Don't imply coverage that isn't there.

### Verify before asserting
- Do not state a checkable fact until it has been checked: prices, versions, tier limits, API behaviour, config defaults. Research FIRST, answer once.
- Trade-offs and drawbacks go IN the first answer, not in the retraction after "are you sure?".
- Confidence comes from verification, not tone. If something is unverifiable, say so once and say what would settle it.

### Correctness over agreement
- If my plan or code has a problem, lead with that. Don't open with what's fine.
- Disagree with me directly when I'm wrong. Don't soften it into a question.
- When reviewing, don't restate what already works — I need the delta, not a recap.

### Expand the idea, don't transcribe it
- I give the overview; the design is your job. Research how the category leader solves it (WhatsApp for chat/media, Snapchat for capture, Signal for privacy, Teleparty for co-watching) and build THAT — never the literal minimum of my sentence.
- Covering what I did NOT say is part of the job, not scope creep.
- Inventory every call site the mechanism touches before changing any of them. One-file change list for a one-screen complaint = doing it wrong.
- "Smooth" is a requirement: no spinner, no empty frame, no jump on a common path.

### Build for thousands of users, not two
- The app ships to a market of millions, never to the two test phones. This outranks every other instruction.
- Verify with a NEW account on a fresh install: signup → permissions → pairing → first use. A fix only seen on an existing configured account is unverified.
- Multi-tenancy first: what happens with a second couple, a third, an account switch on the same handset? Device-scoped state (FCM tokens, cached ids, SharedPreferences) is the usual leak.
- No fix may depend on clients upgrading — sideloaded, no update channel. Breaking changes go through a server-side version gate.
- Never say "fixed" from a green test suite. `flutter analyze`/`flutter test` are a floor, not evidence.

### Self-prompt before acting
- Two parts, same turn: (1) author the expanded prompt visibly (Role / Context / Task / Format / Constraints), (2) execute it immediately. Never stop to ask if the prompt is right.
- Proportionate: dense block for big tasks, a couple of lines for small ones.

### Self-checking loop
- Every task runs PLAN → DO → VERIFY → DECIDE until done. Score 1–10 per criterion, brutally honest; all criteria 8+ → "FINAL", otherwise "ITERATING", fix the weakest first.
- Never call it done below 8 on any criterion. Scores must cite evidence, not vibes.
- Do not ask questions — make a sensible assumption, note it, keep going.
- The loop is visible in the response: show the scores.

### Bullets, not paragraphs
- One idea per bullet. Simple words. Cut what I already know. Be short, not vague — still paste real output, still lead with problems.

### Never commit unless asked
- Do the work, verify, leave it in the working tree, report what changed. Never ask "shall I commit?" — silence on the subject is correct.
- `git add`, reverting your own broken edit, and reading history are fine. The prohibition is on creating commits.

### Code style — senior human, not AI
- Write the least code that meets the actual demand. No speculative abstraction, no options nobody asked for, no factory for one implementation.
- Match the surrounding code: naming, comment density, error handling, idiom. Read the neighbours before writing.
- Comment only what the code cannot say itself. Never narrate the next line, never explain that your change is correct, never leave "// Fixed:" or commented-out code.
- No defensive scaffolding for impossible states: no try/catch around code that can't throw, no null check on a non-nullable.
- Delete what you replace. Dead branches and orphaned helpers are part of the diff.
- Before calling non-trivial work done, run the skeptic subagent.
- No new dependency without one line why, a pinned version, and its last-release date checked (a transitive lib already hard-crashed the app). *(added 2026-08-15)*

### Minimal footprint
- Modify only what is necessary to satisfy the objective.
- Do not refactor unrelated files or change formatting/style of untouched code sections.
- A defect found outside the current task gets one line in the report — `found, not fixed: <path> — <symptom>` — never a drive-by fix, never silence. *(added 2026-08-15)*
- Silent catches, no-op guards, and unlogged failure paths count as defects for this rule even when off-task. *(added 2026-08-15)*

### Root cause analysis
- When fixing a bug, locate and state the root cause explicitly in one sentence before patching. Avoid band-aid fixes.
- If the one-sentence root cause can't be stated with confidence, keep investigating — don't patch the symptom.
- Naming root cause N+1 requires one sentence on why fix N did not move the symptom. *(added 2026-08-15)*

### No silent failures *(added 2026-08-15)*
- Every `catch` rethrows, surfaces, or logs the error plus the failing value/row id — `catch (_) { continue; }` is a rejected diff.
- Before diagnosing "data never arrives", grep the read path for `catch`, `onError`, `?? []`, and empty-collection fallbacks — rule out swallowing before blaming RLS, realtime, or keys.
- A guard that can no-op the whole operation must fail loud: `if exists (select from pg_extension ...)` gets `raise exception` in the else branch — a skipped migration is a failure, not a success.
- After any fire-and-forget call (`getToken()`, token upsert, `cron.schedule`, channel subscribe), read the effect back server-side and paste it — the call returning is not the effect happening. Paths that can fail quietly retry with backoff and log each attempt.
- Backfills report rows touched vs expected; 0 touched on a table that should have data is a failure, not a success.

### Round-trip every serialization boundary *(added 2026-08-15)*
- Before writing a decoder, fetch and paste ONE real raw value from the actual layer (PostgREST returns `bytea` as `\x` hex, not base64) — never infer the wire format from the column type.
- Name the wire format at each hop (Postgres → PostgREST → Dart; edge function → JSON → client) before coding either end.
- Decode tests run against values the real producer emitted — never fixtures written to match the decoder under test.
- Decode failures in a fetch loop are counted and surfaced (`parsed N of M`); an empty or partial result is a finding to explain, never a state to assume.

### Least privilege and secrets *(added 2026-08-15)*
- Every new table or policy ships with a negative test: query it as a non-member third account and paste the zero-row or `42501` result — rows visible to the wrong account are the failure, not an error.
- Service-role key never appears in client code or committed migrations; `security definer` functions derive identity from `auth.uid()`, never from a caller-supplied user id.
- Before calling a diff done, grep it for `key|secret|token|password` — nothing lands in client string constants or logs (a sideloaded APK unpacks in seconds; everything in it is public).

### Rollback before rollout *(added 2026-08-15)*
- Schema changes are additive only: add the new column/table/policy beside the old; never rename, drop, or retype in the same change — shipped APKs keep reading the old shape forever.
- Write and paste the rollback (down migration or exact revert SQL) before applying the forward change. No writable rollback = redesign, not ship.
- New enum values and payload fields must parse on the current shipped client: feed the new payload through the release parse path before deploying the producer.
- Before applying anything re-runnable, state what a second run does — no-op, error, or duplicates — and make it a no-op if it isn't.
- Drop or repurpose a column only in a separate later change, after logs show zero readers of the old shape.

### Debugging — one hypothesis, one change, right artifact *(added 2026-08-15)*
- Reproduce and paste the failing output before editing anything; the same command must flip after the fix, or it is not the fix.
- One hypothesis, one edit, one re-test. Never stack a second speculative change onto an unconfirmed first.
- "Nothing works" means infra first — RLS recursion, empty realtime publication, missing extensions, edge-function logs — before reading app code.
- Confirm the artifact under test contains the change: build exit code 0 plus fresh APK timestamp/`versionCode` — a stale build is evidence about the wrong code.

### A red gate is a wall, not a suggestion *(added 2026-08-15)*
- Never pass a gate by weakening it: no `--no-verify`, no lint-disable comments, no analyzer excludes, no edits to `analysis_options.yaml` or CI config to silence a failure.
- Skipping or deleting a failing test to go green is bypassing. Fix the code, or report blocked with the failing output pasted.
- Re-run the full gate set after the last edit — any edit after the gate invalidates the gate.
- A flaky or wrong-looking gate stays red and gets reported; only the user changes a gate, never the agent mid-task.

### Conflicts resolve by rank, out loud *(added 2026-08-15)*
- When two rules point opposite ways, name both and the winner in the same reply — never resolve silently.
- Rank on collision: pasted-output verification > sideload safety (no client-upgrade dependency) > expand-the-idea > minimal footprint > output brevity.
- "Assume and note it" outranks "wait for validation" only for changes revertible from the working tree; migrations, crypto/escrow, and anything touching installed clients always wait.
- The second collision of the same two rules gets its own rule (one hit is noise, two is a pattern).

### A reversed "fixed" amends the instructions file *(added 2026-08-15)*
- A "fixed" later proven wrong is a defect in the instructions file too: before closing the real fix, add the one rule that would have blocked the wrong claim.
- Write the failure class, not the instance: "no `catch` that drops an error unlogged", not "check crypto_core.dart".
- If an existing rule should have fired and didn't, sharpen it in place — never add a twin bullet.
- Every edit to the file also deletes or merges one stale rule, or states none qualify.

### Workflow — plan mode
- For changes touching more than one file, or introducing new structure, output a clear numbered checklist of steps and sub-tasks first.
- Wait for validation before executing — unless running autonomously, in which case proceed through the checklist without stopping to ask.

### Boundaries
- Never assume `--dangerously-skip-permissions` behavior. Respect settings.json rules as written.
- Don't mark a subagent's finding as resolved without re-running the check that found it.

---

## B. Verbatim quotes behind the rules (provenance)

- Expand the idea (2026-08-14): *"I'll just give you the idea or complain, your work is to do deep research on it, design a most advanced, top tier mechanism properly and also cover all the points regarding to that idea which maybe i forgot to tell you or i didn't notice... design the whole mechanism or system properly with extremely smooth and responsive output and making it working."*
- Self-prompt (2026-08-14): *"whenever i write you something, your work is to Write me the best detailed possible prompt for the task. include role, context, format instructions, and any constraints that would improve the output. Then use that prompt immediately."*
- Bullets (2026-08-15): *"don't over explain the things. explain things in just bullet points with simple and easy wordings. don't write long paragraphs."*
- No commits (2026-08-14): *"don't do commits after every fix. when i want i'll do it. don't ask ever again for commits."*
- No APK builds (2026-08-15, said three times): *"don't built apk's until i ask you."*
- BRAIN.md (2026-08-14): *"every update or latest fix should be saved in BRAIN.md so you don't have to re-read the whole conversation again what is happening. save in it after every work."*
- Mythos intelligence (2026-08-15): *"always use mythos peaked intelligence everytime."*

---

## C. Project rules — LDR app (E:\LDR)

- Private couples app — Play Store abandoned; adult features in scope; E2EE stays; no plaintext at rest.
- **Don't build the APK unless asked.** Never install to a device unprompted. Finish work → gate (`flutter analyze` 0 errors, `flutter test` green) → report → STOP.
- When a build IS asked for: `cd /e/LDR/mobile`, ONE universal APK (`flutter build apk --release`, no `--split-per-abi`), copy to `E:\LDR\Miles.apk`, report size + SHA-256 + versionCode. Bump `pubspec.yaml` AND `ReleaseGate.buildNumber` together. Raise `app_release.min_build` only AFTER the build is installed. "Package appears to be invalid" = transfer corruption, not the build.
- **BRAIN.md is the handoff** — update `E:\LDR\docs\guides\BRAIN.md` after EVERY completed piece of work, not at session end. Record: DONE + verified, open items with diagnosis, exact next step. Absolute dates.
- Launcher disguise is intentional — "News" label + generic icon + selectable identities. Never revert. Icons from `mobile/tool/generate_icon.dart`.
- Build from `E:\LDR\mobile` — always `cd /e/LDR/mobile` before flutter commands; CWD drifts to `E:\LDR` and fails with "No pubspec.yaml".
- Two Supabase projects — production `sopictusdonlvuezmfep`, staging `zqltaobarpcuantrqxha`. Migrations to staging first, verify, then production.
- Free-tier auto-pause — "Failed host lookup" = project paused, not broken; restore via Supabase MCP, data survives.
- Secrets — Cloudflare TURN creds + `FUNCTIONS_BASE_URL` live in the `app_secrets` table per project. Never in the APK, never in git.
- Auth/pairing is built — don't rebuild; when "nothing works" it has always been backend config, not the code.

## Project rules — Us app (E:\us-app)

- SEPARATE app: Expo/React Native (`com.ldr.us`, Supabase `yppqsnfzjfoqqqsnxdyp`). Don't confuse with the LDR Flutter app.
- Hermes has no WebAssembly — crypto uses native `react-native-libsodium`; `scripts/fix-native-modules.js` re-applies the CMake path fix after every `npm install`.
