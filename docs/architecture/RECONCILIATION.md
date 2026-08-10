# Stage R — Cross-domain reconciliation

Resolves the conflicts between the eight independently-designed domain architectures.

## R1 — data

**Conflict.** data.md §7(a) allocates messages.cseq from couple_cursor.next_pos, a counter shared with every other stream in transport.md's vocabulary (chat|reach|capsule|call|closer). That makes messages.cseq SPARSE. messaging.md:99 defines cseq as 'per-couple, dense from 1 over issued values'; messaging.md:318 makes 'EXACTLY ONE CSEQ PER STREAM-MUTATING OPERATION' a server-enforced load-bearing invariant; messaging.md:499 puts 'contiguity of the issued range' in the permanent production canary. data.md's chat_last_pos = next_pos + 1 tracks the head but does not restore density. Secondary: messaging Stage 1 backfills cseq by row_number() over (order by seq, id); transport Stage 3 backfills stream_pos by (created_at, id) — and created_at is client-settable today, which is the exact defect data.md §5 exists to close.

**Decision.** ONE allocator ROW per couple holding TWO independent dense counters, incremented in ONE UPDATE under ONE row lock held to COMMIT.

couple_cursor(couple_id uuid pk, next_pos bigint not null default 0, chat_seq bigint not null default 0), fillfactor 70.

- A chat stream-mutating operation executes: UPDATE couple_cursor SET chat_seq = chat_seq + 1 WHERE couple_id = ? RETURNING chat_seq. It touches next_pos not at all.
- Every other streamed append executes: UPDATE couple_cursor SET next_pos = next_pos + 1 WHERE couple_id = ? RETURNING next_pos.
- Both counters are therefore dense over their own issued values, and both orders are commit orders because both come from the same row lock.

CHAT DOES NOT ENTER couple_stream. messages carries cseq and no stream_pos; messages is not in transport's stream vocabulary. transport's stream enum is closed to reach | capsule | closer | care | cycle | reason | call. Chat's doorbell is messaging's AFTER INSERT trigger onto ch:<couple_id>:<recipient_uid>; chat's catch-up is messaging's token chain over messages(couple_id, cseq). Everything else uses couple_stream.pos and the cs: doorbell.

data.md's chat_last_pos is renamed chat_seq and is promoted from a head-tracker to the chat allocator. messaging.md's chat_streams table is deleted; its last_seq is chat_seq on the allocator row, so stream_last_seq stays a single-row read.

BACKFILL ORDERING, decided: no backfill may order on a column that authenticated can write. messages.cseq backfills by row_number() over (partition by couple_id order by seq, id) — messaging.md's ordering wins, because seq is server-assigned. transport's (created_at, id) ordering is withdrawn for every table; each non-chat streamed table backfills ordered by (id) unless it has a server-assigned monotone column, and the backfill migration must run in the same locked transaction that installs its append trigger.

**Rationale.** Sparse cseq does not actually break messaging's coverage mechanism — coverage is interval-declared and closes over gaps — but it breaks two things that are real: the production canary that is the only place the load-bearing invariant is observable in production, and the arithmetic guarantee that lets pts_count stay deleted. Restoring density costs one extra bigint column on a row that is already locked. Nothing is paid for it.

Keeping chat out of couple_stream is the part that earns money rather than just correctness. Routing chat through couple_stream would (a) double the write for every message — 730M extra rows/year at 50k users — and (b) force the chat doorbell onto the shared cs: topic, which bills 3 per event instead of the 2 that messaging's per-recipient topic achieves. transport.md itself deleted the 'don't subscribe the sender' saving as unachievable on a shared topic; messaging's per-recipient topology is the only shape that actually gets it, and Realtime messages are 85–93% of the bill at every scale past 1,000 users. Two dense counters in one row buys both designs' invariants and the 33% cut, for one column.

The deadlock argument data.md raises against three allocators is fully preserved: it is still one row, one lock, and no function body ever takes two per-couple counter locks.

**Documents to change.** data.md §7(a): rewrite the allocation statement to the two-counter form above; rename chat_last_pos to chat_seq and state it is an allocator, not a head-tracker; delete the sentence describing a single merged counter; amend the CI assertion from 'every table in the stream vocabulary has an append trigger and a NOT NULL cseq' to 'every table registered in stream_registry has an append trigger and a NOT NULL position column named by its registry row, allocated from the counter named by its registry row'. §Migration: add that D-stage ordering gates messaging Stage 1 and transport Stage 3 on the allocator row existing with both columns.

messaging.md: delete the chat_streams table from the data model and from Stage 0; replace every 'chat_streams.last_seq' with 'couple_cursor.chat_seq'; keep every density claim, the contiguity canary and the no-pts_count argument verbatim — they now hold. Stage 0 creates couple_cursor (not chat_streams) via the AFTER INSERT ON couples trigger, covering all four couple-creation sites.

transport.md §C: state that couple_cursor carries two counters and that next_pos is consumed only by non-chat streams; remove messages from the streamed-entity list in §C and from Stage 3; delete the (created_at, id) backfill ordering and replace with the rule above; amend §J and the Stage 7 list so chat is never migrated onto couple_stream. §I is unaffected — call signalling still uses stream='call' on couple_stream.

client.md §A: state explicitly that the STREAM class has two position families — messages.cseq for chat, couple_stream.pos for everything else — and that each has its own stream descriptor. Delete the ambiguity in the current 'in both cases' sentence.

**Invariant after.** THERE IS EXACTLY ONE ALLOCATOR ROW PER COUPLE AND EXACTLY TWO COUNTERS ON IT, EACH DENSE OVER ITS OWN ISSUED VALUES. Both are incremented only by a BEFORE trigger inside the appending row's own transaction, under one row lock held to COMMIT, so allocation order is commit order for both. Enforced by: (a) a CI assertion that no second allocator table exists and that no function body takes two per-couple counter locks; (b) stream_registry, which names exactly one counter and one position column per streamed table, with a CI assertion that every registered table has a matching append trigger and NOT NULL position column; (c) a CI assertion that 'chat' is absent from the couple_stream.stream enum; (d) the permanent production canary asserting contiguity of messages.cseq per couple and of couple_stream.pos per couple, separately.

**Cost of being wrong.** If chat later needs to be in couple_stream after all (for example, a future feature needs one totally-ordered merge of chat with reaches), the repair is a backfill of messages.stream_pos in trigger-first-with-offset form plus a second doorbell — an afternoon's migration on a hash-partitioned table, not a redesign, because the two positions are independent. If instead the second counter turns out to be unnecessary, the cost of having it is one bigint per couple and one extra assignment in a statement that is already executing. The asymmetry is the reason to take this side.

---

## R2 — design/data

**Conflict.** design/data.md v1 added presence(couple_id, updated_at desc). revised/presence.md retires the presence table entirely and replaces it with presence_session, whose defining property is that no indexed column is ever updated so every write stays HOT. revised/data.md §6 already deletes the index and adopts presence_session, but neither document says what becomes of the old table or of the fourteen columns of live data on it, several of which are consumed by other domains.

**Decision.** The retirement is authoritative and the index is never created. Verified on disk: presence(couple_id) has no index today, so there is nothing to drop — the resolution is a NEGATIVE conformance expectation, not a migration.

Column-by-column disposition, which no document currently states, decided here. A relocation migration (call it P-REL) lands before presence Stage K and is a hard gate on Stage M:

MIGRATED
- last_seen -> seeds presence_session.last_confirmed_at, one-time INSERT ... SELECT guarded by greatest(). This is the only presence datum with user-visible continuity value.
- location_label, location_sharing_mode -> user_location (presence.md Stage H).
- current_mood, mood_color, mood_updated_at, avatar_emoji, body_photo_path, checkin_photo_url, checkin_photo_at -> a NEW narrow table user_status(user_id pk, mood, mood_color, mood_at, avatar_emoji, body_photo_path, checkin_photo_path, checkin_photo_at). These are durable per-user content wrongly parked on a presence row; they are SNAPSHOT class per client.md, not in the publication, no indexed column updated. checkin_photo_url is renamed checkin_photo_path in the same statement, which IS the D7 URL normalisation for that column (verified: presence_service.dart:353 writes a full getPublicUrl string).

DISCARDED, deliberately and with no backfill
- is_online, is_typing, typing_in_chat, current_screen, current_activity. These are the class of lie the whole design deletes; their values are unreliable by construction (stuck-online after a hard kill) and migrating them would carry a false state across the cutover.
- latitude, longitude, location_accuracy, location_updated_at. Precise coordinates become a geo broadcast frame on cl: and are never durable again.
- chat_last_read. Deleted outright (presence.md Stage A, messaging open decision 7 both recommend it); chat_receipts.read_cseq is the sole read watermark.

THE TABLE ITSELF: presence.md Stages L then M stand — drop from supabase_realtime, replica identity default, then drop columns, then drop the table. Stage M is additionally gated on a CI grep proving zero `.from('presence')` call sites remain in mobile/lib. Its data_subject_map and retention_policy entries move to presence_session, user_location and user_status in the same migration that drops it; a dropped table that is still in data_subject_map fails CI.

**Rationale.** The index is fatal for the reason data.md §6 gives and presence.md independently derives: presence_server_time.sql stamps updated_at in a BEFORE trigger on every write, at ~18 writes/min/user, on a table carrying replica identity full. An index containing updated_at means no update can ever be HOT — one index insert plus one dead index tuple per heartbeat, ~3,000/s at 10k users against 250 baseline IOPS — to serve a sort over two or three rows per couple. And the query it exists to serve is deleted by presence.md Stage F.

The column disposition matters more than the index, because it is the part that can silently destroy user data. Seven durable columns are sitting on a table three documents agree to drop, and no document says where they go. Discarding the five liveness columns rather than migrating them is the same argument the design makes everywhere else: a durable store that can express 'online' will eventually contradict reality, so the successor schema must not be able to hold the value at all.

**Documents to change.** presence.md: insert Stage P-REL before Stage K with the column table above; add user_status to the data model alongside presence_session and user_location; add to the Stage M gate the CI grep for `.from('presence')`; state that checkin_photo_url is renamed and normalised in P-REL and that D7 therefore has one fewer column to touch.

data.md §6: state that presence carries no index today, so the resolution is a negative expectation rather than a DROP INDEX; add user_status and user_location to §6's index list (user_location(user_id) pk only; user_status(user_id) pk only; neither gets a couple_id index — the partner lookup goes through profiles(couple_id)); add all three tables to table_write_profile with their hot columns declared; add all three to data_subject_map and remove presence from it in the same migration as the drop. §11: strike presence.checkin_photo_url from the D7 normalisation list and reference P-REL instead.

design/data.md v1: mark the presence index row superseded, not moved.

client.md: nothing changes; presence is already SNAPSHOT class.

**Invariant after.** THE DURABLE PRESENCE STORE CANNOT EXPRESS ONLINE-NESS AND CARRIES NO INDEXED COLUMN THAT IS EVER UPDATED. presence_session has exactly one meaningful column, last_confirmed_at, and no state, ended_at, session_id or online_since column — asserted by a schema test that those column names do not exist. No index on presence_session, user_location or user_status intersects that table's declared hot_columns — asserted in CI against table_write_profile and re-asserted every 60 s by conformance over pg_indexes, with the runtime backstop n_tup_hot_upd/n_tup_upd >= 0.9 and its negative test that adds the banned index and asserts the ratio collapses. public.presence does not exist, and no table that data_subject_map names is missing.

**Cost of being wrong.** If a discarded column turns out to have a consumer nobody found, the loss is a per-user display value (a mood emoji, a screen name) that the user can re-set, and the CI grep for `.from('presence')` plus the release-cycle gap between P-REL and Stage M gives two chances to catch it before the table is dropped. If last_seen fails to seed, every couple shows 'last seen: unavailable' until the first anchor write, which is at most one app open. Nothing here can lose a message, a photo or a key.

---

## R3 — data

**Conflict.** data.md §11 makes public=false on all four buckets a migration-defined fact AND a standing 60-second conformance expectation that alarms on drift. crypto.md:204 deliberately keeps a bucket public in its end state ('the public bucket stands on the security argument alone') and crypto.md:272 asserts `select id, public from storage.buckets` matches its OWN checked-in map. Two live plans, one conformance table. Post-crypto the project carries either a permanently-red page-severity alarm — the failure mode data.md itself names as fatal, because a permanently-red alarm gets muted — or a silently weakened assertion.

**Decision.** ALL FOUR BUCKETS ARE public = false, PERMANENTLY, IN EVERY END STATE INCLUDING POST-CRYPTO. crypto.md's public-bucket end state is withdrawn. There is exactly one bucket map, owned by data, and it never changes at crypto's cutover.

Expectation rows, committed in the migration that creates each bucket row:

| kind | key | expected | severity | when it becomes true |
|---|---|---|---|---|
| bucket_flags | couple_media | {public:false, file_size_limit:<n>, allowed_mime_types:[...]} | page | D7 step (d), after path normalisation and the client release |
| bucket_flags | couple_intimate | {public:false, ...} | page | D7 step (d) |
| bucket_flags | chat-bg | {public:false, ...} | page | D7 step (d) |
| bucket_flags | capsule-media | {public:false, ...} | page | D7 step (a) — it is already private today, so this row asserts it stays |

Before D7 step (d) the three public buckets carry an ops_rule_exemption row with reason 'pre-D7 cutover' and a dated expires_at equal to the planned flip date, so the pre-flip state is a declared, expiring exemption rather than an untracked violation, and an overrun becomes a violation on its own schedule.

One expectation row crypto needs and data does not have, added here: kind bucket_path_shape, key <bucket>, expected {uuid_segment_count: 0}, severity warn, evaluated over the 1,000 newest objects per bucket per ops_tick run — a sample, because a full scan of millions of objects every 60 s is not affordable. It fires the moment a non-crypto write path reintroduces a couple_id-prefixed path after cutover.

crypto.md's verification item 7(c) is rewritten. 'An unauthenticated fetch of a public URL asserts the first bytes are not a JPEG magic number' is unrunnable against a private bucket — the fetch 401s and proves nothing about ciphertext. It becomes: mint a signed URL in the test, fetch it, assert the first bytes are not a JPEG magic number, run against a full object and a thumbnail. The assertion's actual content — that the choke-point upload function encrypts — is preserved and its dependence on a public bucket is removed.

**Rationale.** crypto.md never argues that public is BETTER. It withdrew its own cost argument ('the saving is real but small and depends on a cache hit rate this workload will not achieve') and kept only the claim that public is not WORSE once every object is ciphertext at a 32-random-byte path. Harmless is not a reason. Private is strictly safer during the eight-stage, multi-month crypto migration, and strictly safer afterwards against exactly the failure crypto's own guard cannot see: crypto enforces ciphertext 'by construction at a single choke-point upload function, with a CI grep asserting no other call site reaches storage.from(...).upload'. A grep is strong and not absolute. A private bucket is the defence in depth for the case the grep misses — a new upload path added by a future feature, or by the Stage 8 bytea migration itself, which crypto.md names as a plaintext hazard.

The price is small and computable. Private buckets bill uncached at $0.09/GB against $0.03/GB cached. At crypto's own 100k-user egress figure of ~900 GB/month, fully uncached is ~$58/month against ~$20 fully cached — a $38/month delta on a bill crypto itself cites at $5,000–6,500/month. That is 0.7%, and it buys the removal of a permanently-red page alarm on a single-maintainer project whose stated failure mode is exactly that.

Data.md's framing also has to change: its bucket flip is no longer 'the interim, superseded by crypto's root fix'. The two are orthogonal and both permanent. Encryption makes a leaked object worthless; privacy makes it unfetchable. Neither subsumes the other.

**Documents to change.** crypto.md: delete the sentence at :204 keeping a public bucket; replace with a statement that all buckets are private and that the security argument for random paths and per-object DEKs stands independently of the bucket flag, as defence against a leaked SIGNED url, a stale CDN entry and a stolen service-role key — all three of which survive a private bucket, so the argument loses nothing. Rewrite verification 7(a) to reference the single data-owned bucket map rather than its own checked-in map. Rewrite verification 7(c) as above.

data.md §11: strike 'this domain's change is named as the interim' and 'crypto.md's is the root fix'; state that the two are orthogonal permanent controls. Add the bucket_path_shape expectation and its sampling bound to §10 and to the conformance kind list in §1. §Cost: the withdrawal of the +$1.20/+$12/+$105 private-bucket delta stands, but its stated reason is wrong — it must be restated as 'messaging.md and crypto.md both already price this media at the uncached rate, so there is no delta to add', not as 'crypto's topology never gets the cached rate anyway', which misreads crypto.

messaging.md accepted limit 7 and push.md and presence.md: replace 'couple_media remains a public bucket' with a reference to the data-owned bucket map and R5's ownership statement.

**Invariant after.** EVERY STORAGE BUCKET IS PRIVATE, IN EVERY DESIGN'S END STATE, AND THE FLAG IS RE-DERIVED FROM storage.buckets INSIDE PRODUCTION EVERY 60 SECONDS AND COMPARED TO ONE CHECKED-IN MAP. There is exactly one bucket map in the repo and exactly one owner. A pre-cutover public bucket is representable only as an ops_rule_exemption with a dated expires_at, so it is a tracked, expiring state and never a silent one. Enforced by conformance_check() over storage.buckets from ops_tick, with the negative test already specified in data.md verification item 4 (set public = true, assert a bucket violation opens with page severity within one tick).

**Cost of being wrong.** If uncached egress becomes material, the observable is data.md's SLI 9 (storage bytes and egress per bucket) and the repair is flipping one flag on one bucket plus one expectation row — a single migration. The exposure window of being wrong in the other direction is the whole crypto migration plus whatever comes after it, on intimate media, and it is unrecoverable because data.md's own accepted limit 6 states that making a bucket private retracts nothing already distributed. Wrong-and-cheap versus wrong-and-permanent.

---

## R4 — data

**Conflict.** data.md's invariant 'THE WHOLE PROJECT SPENDS EXACTLY TWO OF ITS EIGHT CRON SLOTS' (push_drain 10 s, ops_tick 60 s) is enforced by a conformance expectation that fails on an unexpected job as well as a missing one. It vetoes, without naming them: calling.md's dedicated 1 s drain for kind='call' (:24, :375), calling.md's 30 s reaper sweep (:98, :237), calling.md's partition-management cron for call_signals and call_events (:404), messaging.md's 5 s push_pending drain (:451), crypto.md's hourly purge_expired() plus a 5-minute user-delete cycle (:80, :244), and transport.md's couple_stream compaction job (:254), which is gated on min(applied_pos) rather than a timestamp and so is not a retention_policy entry and has no home at all.

**Decision.** THE BUDGET IS A DECLARED ALLOCATION OF EIGHT, NOT A COUNT OF TWO. A committed cron_job_manifest(jobname, schedule, owner_domain, reason) is the comparand; the conformance expectation is SET EQUALITY against it, so an unexpected job and a missing job both fail, and adding a job is a migration that edits the manifest — which the existing rule ('every migration that changes a conformance-relevant fact updates its expectation row in the same migration') already forces.

THE ADMISSION TEST, which makes this mechanical rather than a judgement call: a job qualifies for a cron slot ONLY if its required cadence is below 60 seconds. Everything at 60 s or slower is an ops_job row dispatched by ops_tick. CI fails any migration containing a cron.schedule whose interval is >= 60 s.

Manifest v1:
| slot | jobname | schedule | owner | why not an ops_job |
|---|---|---|---|---|
| 1 | push_drain | 10 s | push | sub-60 s; also carries lease sweep and its own partition maintenance in one invocation |
| 2 | ops_tick | 60 s | data | it is the dispatcher |
| 3 | miles_breath_cleanup | (legacy) | data | removed by D6 in the same migration that folds it into retention_policy |
| 4 | miles_reach_cleanup | (legacy) | data | removed by D6, same |
| 5-8 | reserved | — | — | claimable only by a migration that edits the manifest and states the reason. Pre-approved future claimant: push_drain_shard_2..k at ~150k users, per push.md's own stated exit. |

PLACEMENT OF THE SIX CONTESTED JOBS:
- calling's 1 s call drain: WITHDRAWN. Its premise is false under push.md's revised design. push.md Path A already fires an immediate statement-level pg_net wake for priority_rank <= 1, so a call's FIRST send attempt is not cron-driven at all; the 10 s cron is the retry floor. Inside a 45 s call TTL that is attempts at roughly t=0, 10, 20, 30, 40 — five, not calling.md's claimed 'roughly one useful retry', which was written against a design where the cron was the primary path.
- TWO AMENDMENTS TO push.md are required to make that true, and they are the price of this decision. (a) The wake debounce must not be one project-wide advisory lock key: class 'call' BYPASSES the debounce entirely, and every other class shares one key. This extends push.md's own doctrine ('priority_rank <= 1 bypasses the rate guard entirely — a deferred ring is a failed ring') from the rate guard to the debounce, and it stops a reach wake swallowing a call wake inside the 2 s debounce window. (b) Invocation budget re-checked at 1k users on Free: ~60k/month undebounced call wakes + ~120k/month debounced reach wakes + 259k/month cron at 10 s = ~439k, inside Free's 500k.
- calling's 30 s reaper: ops_job, schedule_seconds 60. calling.md itself states no correctness depends on it — start_call takes pg_advisory_xact_lock and applies the three-armed reaper before it decides, so the sweeper is telemetry hygiene. 30 s to 60 s costs nothing.
- calling's call_signals / call_events partition management: folded into ops_tick's existing partition create-ahead/drop job. No new row needed.
- messaging's 5 s push_pending drain: WITHDRAWN with push_pending itself, see the third-outbox resolution in the shared contract. push.md's claim-time coalescing (message-class rows for the same (user_id, couple_id) collapse to the greatest watermark) is exactly what push_pending existed to do.
- crypto's purge_expired(): two ops_job rows, schedule_seconds 3600 (expiry sweep) and 240 (user-initiated deletes). 240 rather than 300 so that dispatch jitter on a 60 s tick keeps crypto's published '<= 5 minutes for user-initiated deletes' true as stated rather than true-plus-a-tick.
- transport's couple_stream compaction: ops_job named couple_stream_compact, schedule_seconds 3600, owner transport, registered by data. It is explicitly NOT a retention_policy entry, because its predicate is min(applied_pos) over couple_member_cursor and not a timestamp — data.md §9's job list must name it, and the retention enable gate must not be applied to it.

**Rationale.** Two is the wrong number and eight is the wrong number. Two is wrong because it was set unilaterally by the domain that owns the budget without naming a single one of the three siblings it vetoes, and because it breaks the day push needs a second shard — an exit push.md itself documents. Eight is wrong because Supabase's guidance is a soft cap that is also the horizontal-scaling ceiling, so spending it now caps the app later.

What makes the allocation stable is not the number but the admission test. 'Below 60 seconds' is checkable by CI, cannot be argued, and is the only property that genuinely distinguishes a cron slot from an ops_job row — ops_tick's floor is its own 60 s schedule. Every one of the six contested jobs fails that test except calling's 1 s drain, and calling's 1 s drain fails a different test: its stated justification does not survive push.md's revision.

Set equality rather than a count is what makes the expectation survive the manifest changing. A count breaks on every legitimate addition; a set diff names exactly which job appeared or vanished, which is the information an alert needs to be actionable.

**Documents to change.** data.md: replace the invariant 'THE WHOLE PROJECT SPENDS EXACTLY TWO OF ITS EIGHT CRON SLOTS' with the manifest-set-equality form and the 60 s admission test; add cron_job_manifest to the committed-data list in §2 and to the conformance kinds in §1; §9 must name couple_stream_compact, crypto's two purge jobs and calling's reaper in the ops_tick job list; add the CI rule failing any cron.schedule >= 60 s; state that during D6 the manifest transiently holds four rows and that the unschedule and the manifest edit are one migration.

calling.md: delete the dedicated 1 s call drain from the what-changed summary (:24) and from S2 (:375), and replace it with a reference to push.md Path A plus the undebounced call wake; restate the 30 s reaper as a 60 s ops_job and reassert that nothing correctness-bearing depends on it; delete the standalone partition cron from S7 (:404) in favour of ops_tick's partition job; delete the budget note at :377, which is now the manifest's job.

push.md: adopt the per-class debounce with 'call' exempt; re-state the Free invocation arithmetic with the new figure; restate §8's cron budget open decision (:414) as 'one slot, claimed in the manifest' rather than an internal recommendation.

crypto.md: restate the hourly purge and the 5-minute cycle as ops_job rows at 3600 and 240 seconds, owned by crypto, dispatched by ops_tick; keep the 'forbidden from touching key_requests' rule as a job-body property.

transport.md §G Retention and compaction: restate the pg_cron compaction as ops_job couple_stream_compact at 3600 s and state explicitly that it is not a retention_policy entry and is exempt from the retention enable gate.

messaging.md: delete the 5 s pg_cron drain, the 300-row budget and the push_pending backlog test from :181/:451/:497, and delete 'push_pending rows past N ticks' from the canary at :499, replacing it with push.md's oldest-pending-age SLI.

**Invariant after.** THE SET OF SCHEDULED pg_cron JOBS EQUALS THE COMMITTED cron_job_manifest, AND NO JOB WHOSE CADENCE IS 60 SECONDS OR SLOWER MAY HOLD A SLOT. Enforced by (a) a conformance expectation computing a set difference between cron.job and cron_job_manifest every 60 s, opening a named alert for each direction; (b) a CI grep failing any migration that calls cron.schedule with an interval >= 60 s; (c) the pre-existing rule that a migration changing a conformance-relevant fact must edit its expectation row in the same migration, which here means the manifest. Every maintenance job that is not in the manifest is an ops_job row with a schedule_seconds, a budget_ms and a statement_timeout, run in its own subtransaction so one job's failure cannot prevent the others.

**Cost of being wrong.** If the 10 s floor plus an undebounced call wake still leaves rings arriving late — measurable as push.md's p50/p95(claim_time - created_at) segmented by class, and as calling.md's per-OEM ring success rate — the repair is one push_config UPDATE to the interval, or claiming slot 5 for a 2 s push_drain_call, which is one migration editing one manifest row. Bounded, observable, and reversible. The cost of the other side is that six of eight slots are spent before anyone counts them, and the ceiling push.md needs at 150k users is gone.

---

## R5 — Storage bucket privacy — couple_media is public with permanent unauthenticated URLs whose 

**Conflict.** Storage bucket privacy — couple_media is public with permanent unauthenticated URLs whose first path segment is a guessable couple UUID — was declared another domain's problem by messaging.md (accepted limit 7), push.md and presence.md. revised/data.md §D5/§11 now claims it. Nobody has confirmed the claim, and no document enumerates the rows that hold already-issued public URLs.

**Decision.** SOLE OWNERSHIP CONFIRMED: data. Bucket rows, bucket flags, storage.objects policies, the bucket map, the conformance expectations and the cutover sequence are data's, in D7. messaging.md, push.md and presence.md carry no bucket responsibility and their deferrals are correct rather than negligent. crypto owns object CONTENT (ciphertext, per-object DEK, 32-random-byte path, storage_ledger) and the choke-point upload function; it does not own bucket configuration. That is the seam: data owns the container, crypto owns the contents.

MIGRATION PATH FOR URLs ALREADY STORED IN ROWS. Verified on disk, the affected set is small and enumerable, which is the reason this is a two-release change and not a project:
- presence.checkin_photo_url — stores a full getPublicUrl string (presence_service.dart:353 writes 'checkin_photo_url': url). NORMALISED BY P-REL (see R2), which renames it checkin_photo_path on the new user_status table. D7 does not touch it.
- profiles.chat_bg_image_url — stores a full URL (supabase_repository.dart:372). Normalised in D7 to chat_bg_path.
- personal_vault_items.content — per data.md §11; normalised in D7.
- messages.image_path / voice_path / video_path and presence.body_photo_path already store PATHS, not URLs — chat_repository.dart:157/165/266 build the URL at read time. They need no data migration; only the six getPublicUrl call sites change (chat_repository x3, chat_theme_picker, home_screen, settings_screen).

ORDER, and each step's failure mode if skipped:
(a) Data migration rewrites each stored URL to its object path by stripping the known `/storage/v1/object/public/<bucket>/` prefix, in a transaction, with a counting view merged and observed FIRST per data.md's destructive-migration rule. Rows whose value does not match the expected prefix are left untouched and COUNTED — an unmatched row after the flip is a broken image, so the count must be zero before (d).
(b) Client release replaces all six getPublicUrl call sites with createSignedUrl, and reads the renamed path columns with a fallback to the old column while both exist.
(c) Adoption observed via a server-side counter of signed-URL mints versus total media reads; the gate is a measured number, not a date. On a sideloaded app with no update channel this is the step that cannot be rushed.
(d) Flip public = false, one bucket at a time, and let the exemption row expire.
NO 30-DAY PUBLIC FALLBACK. v1's version left every historical intimate photo world-readable for a month attached to the change advertised as fixing it.

ORDERING AGAINST SIBLINGS: D7(a) must not run against presence.checkin_photo_url after P-REL has already moved it, and must not run before P-REL either — so P-REL strictly precedes D7 and D7's column list is written after P-REL lands. crypto Stage 8 (media out of bytea) writes only new-shape paths through the choke point and is unaffected by D7 in either order.

**Rationale.** Three domains deferring the same problem is how it survived. One owner is the fix, and data is the correct one: it owns migrations, conformance, the privilege manifest and the only mechanism (conformance_check over storage.buckets every 60 s) that can detect the flag being flipped back.

The reason to enumerate the URL columns rather than gesture at them is that the flip is the only user-visible step in the entire ten-stage data plan, and its failure mode is silent — an unmatched row renders as a broken image with no error anywhere, on a photo the user believes is saved. Verifying on disk that only three columns hold URLs and that chat media already holds paths converts this from an open-ended migration into a two-release change with a countable gate.

The counting-view-first rule is data.md's own, and this is exactly the migration it was written for: an unmatched-prefix count of zero is the difference between flipping a flag and breaking every historical check-in photo.

**Documents to change.** data.md §11 and D7: replace 'everything consuming messages.image_path' with the verified enumeration above, including the finding that message media already stores paths and needs no data migration; add the unmatched-prefix counter as an explicit gate on step (d); state the P-REL ordering dependency; add the six client call sites by name so the release-coupled step has a checklist. Open decision 3 stays open (it is genuinely the owner's call, because it is the one step users can feel) but its scope shrinks to three columns.

messaging.md accepted limit 7: replace 'couple_media remains a public bucket ... this is a separate project' with 'bucket privacy is data.md D7; this domain owns only the storage-object deletion on BLOCKED discard'. Keep the flung-GIF and chat-bg orphan findings — those are data.md's storage orphan sweep, and messaging should name it as such rather than as unowned.

push.md, presence.md: replace their bucket deferrals with a one-line reference to data.md D7.

crypto.md 0c: keep the 'dump the live policies verbatim before writing DDL' step — it is a genuine prerequisite for D7 and D7 must consume its output rather than duplicating it.

**Invariant after.** EVERY BUCKET FACT HAS EXACTLY ONE OWNER AND EXACTLY ONE DECLARATION. All four bucket rows, their flags, their size and MIME limits and their storage.objects policies are created by data migrations, carry an ops_expectation row created in the same migration, and are re-derived from the live catalogue every 60 s. No row in public stores a rendered storage URL: enforced by a CI assertion that no column value in the checked-in media-column list matches '/storage/v1/object/public/', and by a CI grep that getPublicUrl appears zero times in mobile/lib after D7 step (b). A bucket appearing in storage.buckets with no expectation row fails conformance.

**Cost of being wrong.** If adoption is misjudged and the flag is flipped while an old build is still in the field, the visible failure is broken images for those users until they update — recoverable in one statement by re-setting public = true and letting the exemption row re-open. If the unmatched-prefix count is not gated and a column shape was missed, the same, plus a data migration to repair the missed shape. Nothing is destroyed: the objects and the paths both survive every step. The cost of leaving it unowned is unbounded and is already accruing.

---

## R6 — data

**Conflict.** data.md v1 said partition messages at 100k users. messaging.md derives 1.46B rows/year and roughly 900 GB at 100k with deliberately unbounded retention, and partitions in its Stage 1 regardless of scale. The ROADMAP records this as 'reconcile to the messaging figure; partition far earlier'.

**Decision.** THERE IS NO USER-COUNT TRIGGER. THE TRIGGER IS A STAGE. messages is HASH-partitioned on couple_id into 32 partitions in messaging Stage 1, unconditionally, while production holds one couple. data.md v1 is the wrong document and its row-count trigger is deleted, as data.md's own §Cost already concedes ('messaging.md is right and v1 is wrong twice'). The ROADMAP's wording 'partition far earlier' is also imprecise and must change: it is not earlier, it is decoupled from user count entirely.

THE PARTITION COUNT IS 32 AND IS A COMMITTED, NON-REVISITABLE DECISION. Changing a hash partition count is a full table rewrite, so it is chosen once. 32 gives ~23M rows per partition at 50k users (the declared app ceiling) and ~46M at 100k; the catch-up query couple_id = X AND cseq > N prunes to exactly one partition. Going to 64 buys nothing and adds 32 relations to a pg_class that data.md already flags as worth watching at ~200 relations.

HASH IS A LOCALITY DECISION, NOT A RETENTION MECHANISM. DROP PARTITION never applies to messages and never will. Chat retention is deliberately zero.

THE 1.46B / 900 GB FIGURE IS RETAINED, AS A DIFFERENT FACT. It is not a partitioning trigger; it is the disk-growth forecast that drives three other decisions: PITR at 10k, the restore-posture change at 50k (a 440 GB logical restore is hours, so the monthly rehearsal stops fitting on a scratch Free project), and the physical-restore-plus-read-replica posture past that. Those are the decisions the number was always answering.

ONE LATENT DEFECT THIS EXPOSES, FIXED HERE: data.md's partition-runway alarm ('every partitioned table has at least three days of future partitions') is meaningful only for RANGE-partitioned tables. messages is HASH and has no runway. Unless the expectation is scoped by partition strategy, messages produces a permanent page-severity runway alarm from the day it is partitioned — precisely the muted-alarm failure data.md names as its own ceiling. The runway expectation is therefore scoped to registered tables whose strategy is range-daily; hash-partitioned tables are exempt BY KIND, not by an exemption row with an expires_at.

**Rationale.** A row-count or user-count trigger for partitioning is answering a question that no longer exists once you accept that partitioning is the one step that gets materially harder with volume. Doing it at one couple costs a locked transaction measured in milliseconds; doing it at 146M rows costs a maintenance window. There is no scale at which deferring is cheaper.

The two documents were also answering different questions with the same number, which is why they looked contradictory. 900 GB at 100k is a real and important number — it is the reason the restore rehearsal stops being feasible and the reason PITR is bought — but it was never evidence about when to partition, because hash partitioning does not reclaim anything.

The runway-alarm scoping is not a detail. data.md is explicit that a permanently-red alarm gets muted and that a muted alarm is indistinguishable from no alarm; shipping messages into a runway check it can never satisfy would mute the one alarm that stands between a dead partition-creation job and 'chat is broken' with the cause three layers away.

**Documents to change.** data.md: §Cost's reconciliation paragraph is already correct and stands. §8's line 'The v1 line partition messages monthly on created_at at 100k users is withdrawn on both counts' stands. What must be ADDED: the partition-runway invariant and its expectation must be scoped to range-partitioned registered tables, with hash-partitioned tables exempt by kind; §9 and the invariant 'EVERY PARTITIONED TABLE HAS AT LEAST THREE DAYS OF FUTURE PARTITIONS' both need that scoping word. §14's pg_partman comparison should note that retention and partitioning are decoupled for messages.

messaging.md: no change. Stage 1, 32 HASH partitions on couple_id, the single locked transaction, and the trigger-first-with-offset fallback for the large-table case all stand. Open decision 5 is closed rather than open: 32 partitions, in Stage 1, single locked transaction, non-revisitable.

ROADMAP.md §3a row R6: rewrite from 'reconcile to the messaging figure; partition far earlier' to 'partitioning is a stage, not a threshold: 32 HASH partitions on couple_id in messaging Stage 1 at any scale. The 1.46B-row / 900 GB figure is retained as the disk-growth forecast driving PITR and restore posture, not as a partitioning trigger.' §4's cost table should gain a 50,000-user row — see the shared cost model.

**Invariant after.** messages IS HASH-PARTITIONED ON couple_id INTO EXACTLY 32 PARTITIONS FROM messaging STAGE 1 ONWARD, AND CARRIES NO RETENTION ENTRY. Enforced by an ops_expectation of kind partition_strategy with expected {table:'public.messages', strategy:'hash', key:'couple_id', count:32}, re-derived every 60 s from pg_partitioned_table and pg_inherits; by a CI assertion that retention_policy contains no row for messages; and by the runway expectation being scoped to strategy='range' so messages cannot generate a runway alarm it can never satisfy. No user-count or row-count threshold appears in any document as a partitioning trigger.

**Cost of being wrong.** If 32 is the wrong count, the repair past 50k users is a full table rewrite of ~440 GB — hours of downtime or a logical-replication cutover. That is the one genuinely expensive way to be wrong here, which is why the count is committed once and stated as non-revisitable rather than left as a default. If the stage-not-threshold call is wrong (it is not), the cost is a locked transaction on a one-couple table, which is milliseconds.

---

## CLIENT-F2 — revised/client

**Conflict.** revised/client.md treats the chat stream as append-only and asserts 'delete_for_everyone and hide_message likewise become position-consuming updates' as CLOSED. No sibling implements it. Verified on disk: delete_message_for_everyone is `update public.messages set deleted_for_everyone = true, deleted_at = now()` (chat_media_cleanup.sql:19-21) and hide_message is an array append to deleted_by (settings_and_delete.sql:35-38); clear_conversation_everyone is a bare DELETE (clear_chat_everyone.sql). messaging.md, which owns chat, files this as Open Decision #8 — recommended, unspecified, unshipped. sync_messages returns only cseq > token.covered_through, so a mutation at cseq 4001 is below a reader at 4200 and is never re-served. cseq cannot simply be bumped: client.md §I reads chat with the keyset cseq < anchor limit 60, so cseq IS display order and bumping it teleports the un-sent message to the bottom of the conversation. Stage C5 then deletes chat_repository.dart:208-210's 300-row refetch, which is today the only self-healing path.

**Decision.** UN-SEND AND HIDE BECOME CONTROL ROWS ON THE CHAT STREAM, MIRRORING clear. The target's cseq is never touched.

WHAT IS WRITTEN. messages.kind is extended to {text, image, video, voice, clear, redact, hide}. messages gains target_cseq bigint null and for_user uuid null. A control row is a real row in messages with: a FRESH cseq allocated from couple_cursor.chat_seq under the same row lock; target_cseq naming the row it acts on; body and media_path NULL; sender_id = the actor.

ON WHICH STREAM. The chat stream, messages.cseq — the same chain sync_messages already serves. Not couple_stream (chat is not in it, per R1). Not a broadcast. Not a side table.

BY WHOM. Three SECURITY DEFINER RPCs, and nothing else, because D4 revokes INSERT/UPDATE/DELETE on messages from authenticated entirely:
- delete_message_for_everyone(target) — one transaction: allocate cseq; insert kind='redact' with target_cseq and for_user NULL; UPDATE the target to body := null, media_path := null, deleted_for_everyone := true, deleted_at := now(); delete the storage object (existing best-effort behaviour).
- hide_message(target) — one transaction: allocate cseq; insert kind='hide' with target_cseq and for_user := auth.uid(); append auth.uid() to the target's deleted_by array (existing behaviour, retained for old clients during rollout).
- clear_conversation_everyone() — unchanged from messaging.md: one cseq, kind='clear' carrying clear_through_cseq, then hard-delete at or below it. The clear row itself is never deleted by a subsequent clear.

THE PROPERTY THAT MAKES IT WORK: for redact, the control row and the target mutation are REDUNDANT WITH EACH OTHER, and both are idempotent and monotone (payload to null, flag to true). A reader whose cursor already passed the target learns from the control row. A reader who has not yet reached the target receives the already-stripped row. A reader who does both converges. Neither path needs the other.

DISPLAY ORDER IS PRESERVED because the target keeps its cseq and its place; a NEW cseq is consumed by the control row, and control rows are never rendered. The client's chat query filters kind not in ('clear','redact','hide'). This is the direct answer to the teleport objection.

HOW AN OFFLINE CLIENT LEARNS. It needs nothing special. Every one of these is a forward cseq strictly above its cursor, so its ordinary chained sync_messages serves it in cseq order in its catch-up pages. A client offline for the whole episode gets redact at 4201, then whatever followed. No digest, no diff, no refetch, no special case.

PER-USER FILTERING AND THE COUNT CHECK. sync_messages filters `for_user is null or for_user = auth.uid()`, so the partner never receives the other's hide rows. LOAD-BEARING CONSEQUENCE: rows_in_range must be computed under the IDENTICAL predicate as the returned rows, per caller. Otherwise the fail-closed count check fails for the partner on every page containing a hide row and wedges the stream permanently.

CONTROL ROWS ARE STORED, NOT ONLY APPLIED. The local mirror stores every row the server serves, including control rows, with its kind; rendering filters, storage does not. This closes the second wedge the audit found — a page containing a control row the client applies but has no place to store makes stored-count short by one, aborts the transaction, never commits the token, and replays the same page forever with a 60 s retry timer burning battery. It also gives the client a replay log for free.

WHEN THE ROW IS HARD-DELETED RATHER THAN FLAGGED. Two cases, and only two.
1. Bulk clear: covered by the clear control row and clear_through_cseq. The client deletes local rows at or below it and raises its local floor so fetch_history never re-fetches them.
2. Anything else that hard-deletes with no control row — a retention reaper, a manual SQL DELETE, a restore from backup, a future feature written by someone who has not read this. No cursor design can catch that, and this one does not pretend to. That is what client.md's stream_digest() is for, and its definition is pinned here because it was the one dimension left undefined: rows_present counts ENTITY rows visible to the caller under the same predicate as sync_messages, over the intersection of the caller's covered range with [floor_pos, stream_last_pos]. It never counts couple_stream rows. Because chat has no couple_stream rows (R1) and because transport states that entity tables are never compacted, the compaction false-positive the audit predicted — every cold start after a compaction pass declaring resync_required on a loop — cannot arise for any stream.

AND THE RULE THAT STOPS THIS RECURRING: no path may remove or alter the payload of a row in a couple's chat stream without allocating a cseq in the same transaction. Enforced three ways: (a) D4 revokes INSERT/UPDATE/DELETE on messages from authenticated, so PostgREST cannot mutate a message at all; (b) a BEFORE UPDATE OR DELETE trigger on messages raises unless a transaction-local flag set only by the four sanctioned RPCs is present — the same set_config('miles.bulk_purge','1',true) idiom transport already uses; (c) the production canary asserts contiguity of messages.cseq per couple, so an operation that mutates without allocating is visible as a stalled counter.

**Rationale.** This is the only shape that satisfies all five constraints simultaneously: it survives both users offline (it is a durable row), it does not depend on a socket (it rides the same HTTP-served token chain), it does not depend on a clock (cseq only), it does not move the target's display position, and it does not require the client to diff.

The redundancy between the control row and the target mutation is what makes it robust rather than merely correct. Every other proposal I considered has a single point of learning: bump the target's cseq (breaks display order), broadcast a deletion event (unreliable, and client.md forbids storing anything from a channel), or make the client diff (client.md explicitly forbids it — 'the engine has no diff function'). Writing both a forward event and a stripped target means the un-send is learned by two independent paths and the client needs whichever one it happens to hit.

Storing control rows rather than only applying them is a small decision with a large consequence: it converts the fail-closed count check from a mechanism that can permanently wedge a stream on a routine user action (partner taps Clear chat) into one that is trivially satisfiable. The advertised safety property — a page the client failed to store cannot advance anything — is preserved exactly; what is removed is its inversion.

The volume is bounded by user deletion actions, which are rare, so consuming a cseq per delete costs nothing measurable against 40 messages/user/day.

**Documents to change.** messaging.md: Open Decision #8 is CLOSED, not recommended — write the three RPC bodies above into the Server operations section; extend the kind enum and add target_cseq and for_user to the messages shape; add the per-caller predicate rule to the sync_messages contract and make it an invariant ('rows_in_range is computed under the identical predicate as the returned rows'); add the BEFORE UPDATE OR DELETE trigger and the revoke to Stage 1; add to the canary a check that no message row has deleted_for_everyone = true with no redact control row naming it. The 'EXACTLY ONE CSEQ PER STREAM-MUTATING OPERATION' invariant now has four operations, not two, and holds for all four.

client.md: replace the assertion that these 'become position-consuming updates' with the concrete mechanism; add to §B that the local mirror stores control rows and that rendering filters on kind; amend the §C apply rule step 4 to state that control rows count toward stored rows; pin the stream_digest definition (rows_present counts entity rows under the caller's predicate, never stream rows); state the C5 gate explicitly — C5 may not delete chat_repository.dart:208-210's refetch until the redact and hide RPCs are LIVE IN PRODUCTION, in the same sentence that already gates C5 on C1. Resolve the sync_state enum: four values in §B against three declared exhaustive in invariant 14 — make it four, and define 'unverified' as 'held locally, below the resync floor, not certified by any token; rendered normally with no badge; exits to committed when a subsequent covered interval includes it, and is never rendered as an error'.

data.md: add messages to the D4 privilege manifest with INSERT/UPDATE/DELETE revoked from authenticated (this is a change — D4 currently plans a column-list INSERT grant on messages, which R-GRANT-LANDMINE withdraws); note that clear_conversation_everyone stays a hard delete per its own open decision 6, and that redact strips payload rather than deleting the row so the chat stream stays dense.

transport.md §D: unchanged for non-chat streams (op='delete' / op='purge' with the suppression flag). Add one sentence that chat's equivalents live on messages.cseq as control rows and are not couple_stream ops.

**Invariant after.** NO ROW IN A COUPLE'S CHAT STREAM MAY BE REMOVED OR HAVE ITS PAYLOAD ALTERED WITHOUT ALLOCATING EXACTLY ONE cseq IN THE SAME TRANSACTION, AND EVERY SUCH OPERATION IS LEARNED AS A FORWARD POSITION BY A READER WHOSE CURSOR HAS ALREADY PASSED THE TARGET. Enforced server-side by: INSERT/UPDATE/DELETE on messages revoked from authenticated so every mutation goes through one of four SECURITY DEFINER RPCs; a BEFORE UPDATE OR DELETE trigger on messages that raises unless a transaction-local flag set only by those RPCs is present; and the production canary asserting per-couple contiguity of messages.cseq plus zero rows with deleted_for_everyone = true lacking a redact control row. Enforced client-side by construction: the engine has no diff function, control rows are stored as well as applied, and rows_in_range is computed under the caller's own predicate so the fail-closed count check can never fail on a correctly-applied page.

**Cost of being wrong.** If control rows prove too costly — they are not; volume is bounded by user deletion actions against 40 messages/user/day — the fallback is making hide local-only, which costs hide fidelity across a reinstall and nothing else; redact must stay on the stream regardless. If the redundancy argument is wrong and a reader can somehow hit neither path, the residual is caught by stream_digest at the next cold start. The cost of NOT deciding this is the attacker's exact sentence, unchanged: a partner un-sends an intimate photo, the row is stripped server-side, and it stays on the other person's screen permanently — and after Stage C5 deletes the refetch, no code path in any of the eight designs recovers it.

---

## GRANT-LANDMINE — hardening_2026_08

**Conflict.** hardening_2026_08.sql:35-46 computes a column list from information_schema AT APPLY TIME and issues `execute format('grant update (%s) on public.profiles to authenticated', cols)`. pg_dump freezes the RESULT, so the next ADD COLUMN produces a column authenticated cannot UPDATE. Verified: the same idiom appears four more times — hardening_couple_id_fix.sql:~30-42 (profiles, UPDATE), :75-80 (capsules, UPDATE, excluding unlocked_at), :83-90 (vault_pin, SELECT, excluding pin_hash), newuser_fixes.sql:162-172 (profiles, UPDATE). newuser_fixes.sql:158-161 documents the dead end in its own comment. This already caused the gender/gender_set production failure. data.md's proposed CI assertion tests only the UPDATE verb, while D4 mandates column ACLs in INSERT on five more tables and vault_pin's existing ACL is SELECT — so the named assertion misses two of the three verbs actually in use.

**Decision.** REMOVE THE MECHANISM, DO NOT GUARD IT. A COLUMN-LEVEL GRANT OR REVOKE IS FORBIDDEN ANYWHERE IN THE PROJECT. Column protection is a BEFORE trigger; secret columns become secret TABLES; neither is a privilege.

PER SITE, with the replacement:
- profiles.couple_id: drop the column ACL, `grant update on public.profiles to authenticated`. guard_couple_id is the real enforcement and it is verified sufficient — it is SECURITY INVOKER, fires `before update of couple_id`, and raises when current_user in ('authenticated','anon'), so a PostgREST PATCH naming the column is refused while a SECURITY DEFINER pairing RPC running as owner is allowed. ONE GAP TO CLOSE IN THE SAME MIGRATION: the trigger covers UPDATE only. Extend it to BEFORE INSERT OR UPDATE, or the same PATCH-shaped attack works through an INSERT if authenticated ever holds INSERT on profiles.
- capsules.unlocked_at: replace the column ACL with a BEFORE UPDATE trigger doing `new.unlocked_at := old.unlocked_at` unless a transaction-local flag set by the unlock RPC is present, then `grant update on public.capsules to authenticated`.
- vault_pin.pin_hash: verified that the client never selects from vault_pin — all three access paths are RPCs (has_vault_pin, set_vault_pin, verify_vault_pin at vault_repository.dart:37/42/46). So the column SELECT ACL is replaced by a TABLE-level `revoke all on public.vault_pin from authenticated, anon`. Table-level revokes are fixed statements and are dump-stable. No table split is needed. This generalises: a column authenticated must not read becomes a table authenticated cannot read, reached only through SECURITY DEFINER.
- messages, call_invites, reach_events, care_nudges, account_deletions server-stamped timestamps: D4's planned column-list INSERT grants are WITHDRAWN — they would relocate the exact same landmine onto five more tables, with the client already writing a column (reply_to_id) that exists in zero .sql file today. CONDITION (ii) OF THE RETENTION ENABLE GATE IS DELETED. A BEFORE trigger doing `new.created_at := now()` on INSERT and `new.created_at := old.created_at` on UPDATE overwrites whatever the client sent, which is complete enforcement by itself; gate condition (i) already mandates that trigger, so (ii) bought nothing and created the exposure. Gate conditions (i) trigger-stamped and (iii) leading-column index both stand.

ORDERING FINDING NOT IN ANY DOCUMENT, AND IT MATTERS: D1's baseline is `supabase db dump --schema public` of production, so the FROZEN column-grant lists for profiles, capsules and vault_pin are captured verbatim into 00000000000000_baseline.sql. The landmine therefore survives the entire migration project inside the baseline unless something removes it. Insert STAGE D1a immediately after the baseline is repaired and before D2: one migration issuing the fixed statements above. It is four statements, it un-breaks ADD COLUMN on the day it lands, and it lets CI assertion 2 go green immediately instead of at D4.

THE CI ASSERTIONS — three, because one verb is not enough and enumeration goes stale:
1. NO COMPUTED GRANTS. CI greps supabase/migrations/**.sql and fails on information_schema, pg_attribute or pg_catalog appearing inside a `do $$` block, inside `execute format(`, or within ten lines of a grant or revoke. Hard failure, not a warning.
2. NO COLUMN ACL EXISTS, IN ANY VERB, ON ANY TABLE, EVER. `select count(*) from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and a.attacl is not null` must be ZERO. pg_attribute.attacl is populated ONLY when a column-level grant or revoke has actually been issued, which is exactly the class being banned — unlike information_schema.column_privileges, which also reports table-level grants and would never be zero. This assertion enumerates nothing, so it cannot go stale, and it covers INSERT, UPDATE and SELECT and every future verb without being edited. It REPLACES data.md's per-verb has_column_privilege loop over protected_column, and the protected_column table itself is deleted.
3. THE REGRESSION TEST THAT REPRODUCES THE ORIGINAL FAILURE. In CI, after applying every migration: `alter table public.profiles add column ci_probe text`, assert has_column_privilege('authenticated','public.profiles','ci_probe','UPDATE') is true, roll back; repeat for every table in table_privilege that grants UPDATE to authenticated. This is byte-for-byte the /role-setup dead end that newuser_fixes.sql:158-161 documents, and it fails against today's schema — which is the proof it is worth writing.

PLUS A PRODUCTION CONFORMANCE EXPECTATION, because CI cannot see a grant typed into the dashboard: kind column_acl_absent, key 'public', expected {count: 0}, severity page, evaluated by conformance_check() from ops_tick every 60 s using assertion 2's query.

OWNER: DATA. Privileges are §5 and D4; data owns the migration wrapper, the CI harness, the conformance mechanism and the privilege manifest. No other domain may issue a grant.

**Rationale.** data.md already reached the right conclusion for profiles and then abandoned it two sections later — it argues 'keeping the ACL keeps the landmine; the trigger is the actual enforcement' for profiles, then makes a column ACL a MANDATORY precondition on roughly six tables in the retention gate. Applying its own best argument uniformly is the whole fix.

The reason to ban the mechanism rather than assert over it is that every assertion of the form 'for each column, for each verb, check the privilege' is an enumeration, and enumerations rot. data.md's version rotted before it shipped: it covers UPDATE, while D4 mandates INSERT ACLs on five tables and vault_pin's live ACL is SELECT. The pg_attribute.attacl count is a single scalar that is zero or is not, covers every verb and every future table, and needs no maintenance. It is also the only form that survives someone adding a table next year.

The three replacements are each strictly stronger than the ACL they remove. A BEFORE trigger fires for every write path including the SQL editor, which a grant does not — a grant is bypassed entirely by any SECURITY DEFINER function running as owner. A table-level revoke on vault_pin is enforced against the same population and is dump-stable. And the retention timestamp trigger overwrites the value rather than refusing the statement, so it is enforcement that cannot be routed around at all.

D1a exists because a baseline taken by pg_dump is a photograph of the landmine. Everything downstream in data.md assumes the baseline is a starting point to build on; here it is a starting point that contains a live production defect, and nothing in the ten-stage plan removes it before D4.

**Documents to change.** data.md: §5 — replace the protected_column concept and its has_column_privilege assertion with the three assertions above; delete the protected_column table from the committed-data list and from §2; state the ban on column-level grants as a rule with the pg_attribute.attacl assertion as its enforcement. §8 — delete retention enable-gate condition (ii) entirely and state why (it buys nothing over condition (i) and it is what creates the exposure). §Migration — insert Stage D1a between D1 and D2 with the four statements and the guard_couple_id INSERT extension; amend D4 to declare table_privilege only, with no column ACLs anywhere; amend D4's gate ('grep the client for any insert naming a revoked column') to be unnecessary for columns and to apply only to table-level revokes. §10 — add the column_acl_absent conformance kind. Verification item 9 — replace with the three assertions and keep the ADD COLUMN regression test verbatim, it is the right test. Invariant 'EVERY PRIVILEGE IS DECLARED IN THE REPO' — restate as 'every privilege is declared in the repo AT TABLE LEVEL; no column-level grant or revoke exists anywhere, asserted as pg_attribute.attacl IS NULL for every column in public'.

crypto.md: verification item 4 must be rewritten. It currently asserts has_column_privilege('authenticated', table, column, 'UPDATE') is FALSE for every server-owned timestamp — under this resolution no column ACL exists, so that assertion inverts and would fail. Replace with: for each server-owned timestamp column, assert a BEFORE trigger exists that overwrites it (join retention_policy/table_write_profile to pg_trigger), AND keep the table-level half verbatim, which is already correct and dump-stable. Verification item 5 is already table-level and stands unchanged — it is the model for the whole resolution.

messaging.md, calling.md, push.md: none of them issue grants; they must not start. The contract states that only data may.

ROADMAP.md §3a: the paragraph on the landmine should name the pg_attribute.attacl assertion and D1a, since 'a CI assertion catches it' is currently the whole of the remedy and it is the assertion's SHAPE that determines whether it works.

**Invariant after.** NO COLUMN-LEVEL GRANT OR REVOKE EXISTS IN THE DATABASE, AND NO MIGRATION MAY COMPUTE A GRANT AT APPLY TIME. Column protection is a BEFORE trigger; a column authenticated must not read is a table authenticated cannot read, reached only through SECURITY DEFINER. Enforced by (a) a CI grep failing information_schema / pg_attribute / pg_catalog inside any do-block, execute format, or within ten lines of a grant or revoke; (b) a CI and conformance assertion that pg_attribute.attacl is NULL for every column of every table in public, which covers every verb and every future table without enumerating anything; (c) a CI regression test that adds a column to each granted table and asserts authenticated can UPDATE it — the exact assertion that would have caught gender/gender_set; (d) a page-severity conformance expectation re-running (b) inside production every 60 seconds, because CI cannot see a grant typed into the dashboard.

**Cost of being wrong.** Dropping a column ACL in favour of a trigger is only wrong if a trigger cannot express the constraint, and exactly one case exists — a SELECT restriction, which a trigger cannot do. That case is vault_pin.pin_hash, and it is verified that the client reads it through no path but RPCs, so a table-level revoke covers it with no behaviour change. If some future column genuinely needs per-column SELECT restriction, the answer is a second table, which costs one join and is dump-stable. Against that: leaving column ACLs in place means the next ADD COLUMN on profiles, capsules, messages, call_invites, reach_events, care_nudges, account_deletions or vault_pin produces a production dead end whose error message ('permission denied for column X') points at the wrong thing, exactly as it did for gender/gender_set — and D4 as currently written would multiply the affected tables from three to eight.

---

# Shared contract

THE MILES SHARED CONTRACT v1. Every one of the eight designs is a downstream reader of this document. Where a design contradicts it, this wins and that design is edited. It is committed as docs/architecture/CONTRACT.md, and the machine-checkable half of it lives in the repo as data tables (stream_registry, cron_job_manifest, realtime_topic_registry, table_owner, bucket_map) with conformance expectations over each.

=====================================================================
1. POSITIONS AND COUNTERS — WHO ALLOCATES, AND HOW MANY EXIST
=====================================================================
THERE IS EXACTLY ONE ALLOCATOR ROW PER COUPLE AND EXACTLY TWO COUNTERS ON IT.

  couple_cursor(couple_id uuid pk, next_pos bigint not null default 0, chat_seq bigint not null default 0), fillfactor 70, no index other than the pk, created by an AFTER INSERT ON couples trigger so all four couple-creation sites are covered by construction.

- chat_seq is the chat allocator. Consumed by exactly four operations: send_message, clear_conversation_everyone, delete_message_for_everyone, hide_message. Dense over its issued values.
- next_pos is the general stream allocator. Consumed by every other streamed append, one per append. Dense over its issued values.
- Both are incremented by a BEFORE trigger inside the appending row's own transaction, in ONE UPDATE, under ONE row lock held to COMMIT. Allocation order is therefore commit order for both, and a reader observing position N is guaranteed every issued position below N is already visible.
- No function body may take two per-couple counter locks. There is one row, so there is one lock.

WITHDRAWN BY THIS CONTRACT: transport's couple_cursor.next_pos as chat's source; messaging's chat_streams table; push's couple_seq table; data.md's chat_last_pos-as-head-tracker. All are the same row under four names.

POSITION COLUMNS. Every streamed table has exactly one, named by its stream_registry row:
  messages.cseq  <- chat_seq         (chat only; messages has NO stream_pos and is NOT in couple_stream)
  <entity>.stream_pos <- next_pos    (every other streamed table), mirrored as couple_stream.pos

STREAM VOCABULARY, closed enum, CI-asserted, 'chat' deliberately absent:
  reach | capsule | closer | care | cycle | reason | call

BACKFILL RULE: no backfill may order on a column that authenticated can write. messages.cseq backfills by row_number() over (partition by couple_id order by seq, id). Every other table backfills by (id) unless it has a server-assigned monotone column, in the same locked transaction that installs its append trigger. transport's (created_at, id) ordering is withdrawn.

MUTATION RULE: no path may remove a row or alter its payload inside a couple's stream without allocating exactly one position in the same transaction. On chat that is a control row (kind in redact | hide | clear). On every other stream it is a couple_stream row with op in delete | purge. Bulk purge costs exactly one position, with the per-row trigger suppressed by set_config('miles.bulk_purge','1',true).

=====================================================================
2. READ CURSORS — WHAT A CLIENT MAY NAME
=====================================================================
Three cursor mechanisms exist and are NOT unified, because unifying them would mean building a token chain for eight collections that do not have one. What IS unified is the safety property:

  NO INTEGER THAT ARRIVED OVER A SOCKET MAY EVER REACH A READ CURSOR, A WATERMARK, OR A HIGHEST-SEEN VARIABLE. A doorbell is one bit: go read.

  (a) CHAT — an opaque HMAC coverage token, chained. The only mechanism that mints a watermark. read_up_to is the sole client integer and is clamped server-side to least(read_up_to, token.covered_through). Owner: messaging.
  (b) GENERAL STREAM — a bigint local_cursor read from couple_stream by the client itself, advanced only after each row's local apply commits. Owner: transport.
  (c) PUSH SUPPRESSION — push_devices.cursor_seq, greatest()-only, self-reported. It is an OPTIMISATION INPUT, never an invariant: a device that lies suppresses only its own doorbells and stays fully recoverable by catch-up. Owner: push.

client.md's Invariant 1 ('no RPC accepts a bigint position naming a read location, ENFORCED SERVER-SIDE') is FALSE for (b) and (c) and is hereby NARROWED to the socket rule above, which is true everywhere and is transport's own F2. The residual is recorded in remaining_conflicts.

COVERAGE RULE, common to (a) and (b): every paged read returns (rows, covered_from, covered_through, rows_in_range, stream_last_pos, next_cursor). The client merges the INTERVAL, never the positions of the rows it received. has_more is stream_last_pos > covered_through, a server fact. rows_in_range is computed under the IDENTICAL predicate as the returned rows, per caller — this is load-bearing for per-user control rows and its violation wedges a stream permanently. Control and op rows are STORED as well as applied, so the fail-closed count check counts them.

=====================================================================
3. OWNERSHIP — ONE OWNER PER SHARED THING (full map in ownership_map)
=====================================================================
Ownership means: the owner writes the DDL, the migration, the expectation row and the tests. Other domains are readers and may propose, not merge. A shared object with two owners is a merge conflict at best and a hole at worst.

The single hardest rule: ONLY THE DATA DOMAIN MAY ISSUE A GRANT OR REVOKE, and only at table level. pg_attribute.attacl is NULL for every column in public, asserted in CI and every 60 s in production.

=====================================================================
4. RLS ON realtime.messages — ONE POLICY SET, ONE OWNER
=====================================================================
Three domains each planned their own (transport Stage 1a, presence Stage C, crypto Stage 0a, plus messaging Stage 4 and calling S4). Resolved:

- OWNER: data. All policies on realtime.messages are created by data migrations. No other domain writes one.
- SHAPE: exactly four policies — broadcast SELECT, broadcast INSERT, presence SELECT, presence INSERT — all TO authenticated, all with USING and WITH CHECK stated separately, and each predicate is a single call to one SECURITY DEFINER helper:
    realtime_topic_allowed(topic text, verb text) returns boolean, STABLE, PARALLEL SAFE.
  The helper resolves the caller's couple once via (select public.current_user_couple_id()) — the documented 11,000 ms -> 7 ms join-avoidance shape — and matches the topic against the closed class table in §5.
- WHY A FUNCTION AND NOT INLINE PREDICATES: a function body is DDL, so `supabase db diff` and the migration checksum both cover it. Adding a topic class becomes one reviewed function body instead of four policy rewrites across three domains' migrations. This also closes the audit's ops_expectation-is-unverified-reference-data finding for this class.
- NOT ONE MIGRATION, ONE OWNER. data.md's 'ONE migration shared by three domains' is impossible as written: transport Stage 1a policies cover the LEGACY public topic names while presence C and messaging S4 introduce new ones. It is one migration PER TOPIC-VOCABULARY GENERATION, all authored by data, each editing the same helper.
- OPERATIONAL DEPENDENCY, NOT AN ASSUMPTION: DB_POOL_SIZE >= 20, raised in the dashboard and recorded, before ANY private-channel stage ships (transport 1b, presence C, crypto 0a, messaging 3). Read back through the Management API as a conformance expectation. A pool-bound join TIMES OUT rather than returning too_many_joins, so the measured signal is join latency and timeout rate, never too_many_joins.

=====================================================================
5. NAMING — TOPICS AND STREAMS
=====================================================================
TOPIC GRAMMAR: <class>:<scope>[:<qualifier>], class from a closed enum, scope always a UUID. A topic string is unconstructible without a non-null id, which makes mood_lamp:none unrepresentable rather than fixed.

| class | topic | private | client read | client write | payload owner | lifecycle owner |
|---|---|---|---|---|---|---|
| cs  | cs:<couple_id>                    | yes | members | NONE | transport | transport |
| cl  | cl:<couple_id>                    | yes | members, gated on reciprocal share_presence | same | presence | transport |
| ch  | ch:<couple_id>:<recipient_uid>    | yes | that user only | that user's PARTNER only (typing) | messaging | transport |
| dev | dev:<user_id>:<device_id>         | yes | own only | NONE | push | transport |
| rtc | rtc:<call_id>                     | yes | the two parties | the two parties | calling | transport |
| rt  | rt:<couple_id>:<session_id>       | yes | members | members | feature (lint allowlist) | transport |

RENAMES, each with its reason:
- presence's couple:<id>:live -> cl:<couple_id>. presence's couple:<id>:msg is DELETED: it existed only so the privacy toggle could switch off typing without breaking chat delivery, and chat delivery now lives on ch:, which is outside the privacy predicate by construction. Presence's requirement is satisfied exactly, with one fewer channel per device.
- messaging's chat:<couple>:<uid> -> ch:<couple_id>:<recipient_uid>. Fits the class grammar.
- calling's call:<call_id> -> rtc:<call_id>. 'call' is already a STREAM name in couple_stream's enum, and the LEGACY public topic is literally call:<couple_id> — a distinct class makes it impossible for a legacy client to join the new private topic during calling's S3/S4 dual-run.
- ALL LEGACY PUBLIC TOPICS (mood_burst, mood_lamp, screen_presence, capsule_proximity, touch, call:<couple_id>, presence:<id>) are retired, not renamed. Until they are, transport Stage 1a gives each an RLS policy through the same helper — closing a live breach is the highest-value-per-risk change in the whole programme and it ships first.

ALWAYS-ON CHANNELS PER DEVICE: 3 (cs, cl, ch) plus rtc during a call and rt during an interactive surface. NO FEATURE CALLS .channel(). Enforced by a static CI test asserting no source file outside the transport constructs a topic string or calls sendBroadcastMessage.

=====================================================================
6. THE THREE OUTBOXES BECOME ONE, AND THE THIRD IS NAMED
=====================================================================
push_outbox (push.md's shape: dedupe_key unique, watermark, priority_rank, daily range partitions) is the ONE server-side notification obligation table. push_devices (unique on (user_id, token_hash)) is the ONE device table.
- calling.md's device_tokens and its second push_outbox are WITHDRAWN; its needs fold in as columns and constraints (deadline_at, CHECK (priority <> 'high' OR kind = 'call'), the per-device hourly high-priority budget).
- calling.md's 'abandoned' state is ADOPTED into the state enum, which becomes pending | inflight | sent | superseded | abandoned | dead. push.md's set has no state for 'a ring that was never sent because its deadline passed', and superseded does not mean that. This is a one-word addition that keeps calling's push_abandoned telemetry expressible.
- messaging.md's push_pending is WITHDRAWN — the THIRD outbox, which the reconciliation section never named. push.md's claim-time coalescing (message-class rows for the same (user_id, couple_id) collapse to the greatest watermark; the rest become superseded) does exactly what push_pending was designed to do. Its row-count argument is answered by daily partitions with reclaim by DROP at 24 h for sent/superseded.
- OBLIGATION/EVIDENCE RULE, project-wide: an obligation row is written by the party that CAUSED the work, in the same transaction as its cause. An evidence row is written by the party that DID the work. A proxy's HTTP status is neither. pg_net returning 200 and an edge function returning 200 both prove only that the function was reached. Delivery is claimed only from push_receipts. net._http_response is a bounded diagnostic and is never evidence.
- WAKE DEBOUNCE: per event_class, and class 'call' bypasses the debounce entirely. This extends push.md's own 'a deferred ring is a failed ring' rule from the rate guard to the debounce, and it is what makes R4's withdrawal of calling's 1 s cron safe.

=====================================================================
7. CONFIG, CLOCKS, AND THE THINGS THAT MAY NOT BE DEPENDED ON
=====================================================================
- ONE runtime config table: app_runtime_config (transport's app_config and presence's app_runtime_config are one table), one row per couple plus one global row, read over plain HTTP so it works with a dead socket. It is the revert lever for every client-side stage in every domain. Flag namespace is <domain>_<name>.
- NO DEVICE CLOCK APPEARS IN ANY CONTROL DECISION IN ANY DOMAIN. Durable freshness is a server-computed AGE, never a timestamp on the wire. Client scheduling is a monotonic Stopwatch from process start. Exactly ONE whitelisted DateTime.now() call site exists project-wide (presence.md's cold-start coarse bucket) and client.md's clock-hostility CI gate names it; stream_digest's '<= once per 24 h' cap is therefore RESTATED as 'once per cold start', because the 24 h cap needs a second whitelist slot that does not exist.
- POSTGRES now() IS TRANSACTION-START TIME and is not monotonic across overlapping transactions. It may be used for retention ('old enough') and for server-stamped display values. It may NEVER be used for ordering, for a cursor, or for a comparison that decides delivery. Ordering is always a position.
- NOTHING IN ANY DESIGN MAY DEPEND ON: both users online, the same network, the app foregrounded, correct device clocks, or a reliable socket. Every one of the eight designs must be able to state, per mechanism, which of the five it would otherwise have needed and what replaced it.

=====================================================================
8. THE SINGLE COST MODEL — ONE TABLE, QUOTED BY REFERENCE
=====================================================================
Three models existed and priced disjoint event populations, which is why they looked like disagreements: messaging priced chat only (7,200 billable/user/month), transport priced everything including interactive-canvas features (planning midpoint 30,000/user/month, range 15k-60k), crypto quoted the research totals. They compose; they do not conflict. The composed model is authoritative and lives in data.md §Cost. Every other document quotes it by reference and states no total of its own.

BASE ASSUMPTIONS, one set, all of them flagged as assumptions:
  2 users/couple. 40 user-messages/user/day (messaging's; data adopted it; v1's 7/day was ~6x low). Peak concurrency 8% of registered — INFERRED, not measured. Evening concentration 0.5. Billable Realtime = events x (recipients + 1). Broadcast with self:false bills 2 on a per-recipient topic and 3 on a shared one. PRESENCE BILLS 3 ALWAYS — there is no self:false for presence.

EVENT BUDGET, chat-only user, after the ch: per-recipient topology:
  chat doorbells 40 -> 80 billable | receipt hints 40 -> 80 | typing 120 -> 240 | presence transitions 16 -> 48 | screen/misc 20 -> 60 | liveness probes 10 -> 30. Subtotal ~538 billable/day, ~16,000/month.
  Interactive-feature user adds ~1,500 billable/day. PLANNING MIDPOINT: 30,000 billable/user/month.

COMPOSED TOTALS (Supabase list price; TURN and FCM separate):
  1,000 users     ~ $110-135/mo   (transport ~$88 minus the fan-out saving, plus disk/storage, plus staging $0-25)
  10,000 users    ~ $960/mo       (Realtime ~$700, base+conn+compute ~$50, disk+IOPS+media ~$79, staging $25, PITR $100, crypto ~$6)
  50,000 users    ~ $4,200/mo     (Realtime ~$3,550, compute ~$150, disk ~$54, IOPS ~$60, media ~$255, egress ~$67, staging $25)
  100,000 users   NOT SUPPORTED   (peak concurrency 80% of the 10,000 hard cap with no reconnect headroom; interactive-session broadcast ~5x over the 2,500 msg/s ceiling)

THE NUMBER THE OWNER MUST SEE: the composed 50k figure is roughly 3x messaging.md's $1,540, because messaging prices no typing beyond amortisation and no interactive-canvas traffic at all. It does not move the CEILING — the ceiling is connections and message rate, not money — but the declared app ceiling of 50,000 users costs about three times what the messaging document implies. The ROADMAP's §4 table has no 50k row and must gain one.

DOMINANT TERM AT EVERY SCALE PAST 1,000: Realtime messages, 85-93% of the bill, and it is superlinear in ENGAGEMENT rather than in users. The budget is therefore set by the rate limits in the transport's single send path, not by growth. The largest and most variable term — interactive-canvas events — is also the only one that is designable away.

FCM is free at every tier. Cloudflare TURN is $0.05/GB after 1 TB free, billed on RELAYED bandwidth with no server-side quota and no per-call credential scoping — which is why the 100k 'move rt: onto the WebRTC data channel' exit is NOT free and is conditional on the peer connection being non-relayed. The unconditional exit past 50k is self-hosted Realtime.

=====================================================================
9. HOW A NEW SHARED THING GETS ADDED, SO THIS CANNOT RECUR
=====================================================================
A migration that creates a bucket, a cron job, a partitioned table, a retention entry, a stream, a realtime topic class or an allocator FAILS CI unless, in the SAME migration, it: (a) inserts its ops_expectation row; (b) inserts its registry row (stream_registry / cron_job_manifest / realtime_topic_registry / bucket_map / table_owner) naming its owning domain; (c) for a cron job, satisfies the sub-60-second admission test. Registry membership is asserted by SET EQUALITY against the live catalogue every 60 seconds inside production, so both an unexpected object and a missing one open a named alert with a severity and an age. The expectation is not documentation; it is the thing that makes the change detectable when someone undoes it by hand.

# Ownership map

Exactly one owning domain per shared resource. Owner writes the DDL, the migration, the expectation row and the tests; everyone else is a reader who may propose, not merge. Asserted by a committed table_owner(object_kind, object_name, owner_domain) with set-equality conformance against the live catalogue.

TABLES — POSITION AND SYNC
  couple_cursor (allocator, next_pos + chat_seq)     -> DATA (schema, CI, both counters' semantics fixed by the contract)
  couple_stream                                      -> TRANSPORT
  couple_member_cursor                               -> TRANSPORT
  messages (+ partitions), chat_receipts             -> MESSAGING
  chat_streams                                       -> WITHDRAWN (folded into couple_cursor.chat_seq)
  couple_seq                                         -> WITHDRAWN (folded into couple_cursor)

TABLES — NOTIFICATION
  push_outbox (daily partitions)                     -> PUSH   (calling's second push_outbox withdrawn; 'abandoned' state adopted)
  push_devices                                       -> PUSH   (calling's device_tokens withdrawn)
  push_receipts (daily partitions), push_config      -> PUSH
  push_pending                                       -> WITHDRAWN (the third outbox; superseded by push's claim-time coalescing)
  device_push_budget                                 -> PUSH   (calling's high-priority ceiling, folded in)

TABLES — CALLING
  calls, call_signals (daily), call_events (daily)   -> CALLING
  call_invites                                       -> CALLING (retired at S7; the interim 10-minute SDP-null-keep-row entry is DATA's retention registry)

TABLES — PRESENCE
  presence_session, user_location, user_status       -> PRESENCE  (user_status is new in R2 and carries mood/avatar/body_photo/checkin)
  public.presence (legacy)                           -> PRESENCE  (owns its retirement: P-REL, then K, L, M)

TABLES — CRYPTO
  devices, couple_epochs, couple_key_wraps, user_key_wraps, key_revocations, recovery_credentials, key_requests, storage_ledger (monthly) -> CRYPTO

TABLES — OPS, POLICY AND LIFECYCLE (all DATA)
  ops_event, ops_alert, ops_expectation, ops_rule_exemption, ops_job, schema_migration_checksum,
  retention_policy, table_privilege, table_write_profile, data_subject_map, account_deletions, couple_notice,
  and the four registries: stream_registry, cron_job_manifest, realtime_topic_registry, bucket_map, plus table_owner itself.
  protected_column -> WITHDRAWN (column ACLs are banned outright; see GRANT-LANDMINE).

TABLES — SHARED CONFIG
  app_runtime_config  -> DATA owns the table; transport's app_config is the same table under another name and is withdrawn.
                         Flag namespace is <domain>_<name>; each domain owns its own flag rows and none other's.
  vault_pin           -> DATA owns the privilege posture (table-level revoke all from authenticated/anon); the vault feature owns the three RPCs.

STORAGE BUCKETS — ALL DATA, sole owner, confirmed against messaging/push/presence deferrals (R5)
  couple_media      -> DATA   (public=false at D7 step d; largest writer is messaging)
  couple_intimate   -> DATA   (public=false at D7 step d)
  chat-bg           -> DATA   (public=false at D7 step d)
  capsule-media     -> DATA   (already private; the expectation asserts it stays)
  exports (new)     -> DATA   (private; async export job target)
  Object CONTENT (ciphertext, per-object DEK, 32-random-byte path, the choke-point upload function, storage_ledger) -> CRYPTO.
  The seam: data owns the container, crypto owns the contents. Neither may edit the other's assertions.

pg_cron SLOTS — 8 total, allocation owned by DATA via cron_job_manifest, admission test = cadence < 60 s
  1  push_drain            10 s   -> PUSH      (drain + lease sweep + its own partition maintenance, one invocation)
  2  ops_tick              60 s   -> DATA      (the dispatcher)
  3  miles_breath_cleanup  legacy -> DATA      (unscheduled at D6, same migration that folds it into retention_policy)
  4  miles_reach_cleanup   legacy -> DATA      (unscheduled at D6, same)
  5-8 RESERVED                    -> unclaimed. Pre-approved future claimant: push_drain_shard_2..k at ~150k users.
  DISPATCHED AS ops_job ROWS, NOT SLOTS: conformance evaluation; retention batches; partition create-ahead/drop (covers push, calling, crypto, realtime.messages); SLI evaluation; alert open/close; storage orphan sweep; crypto purge_expired 3600 s; crypto user-delete purge 240 s; calling reaper 60 s; couple_stream_compact 3600 s (TRANSPORT's predicate, DATA's dispatcher, explicitly NOT a retention_policy entry); account-deletion purge batches; export jobs.

REALTIME TOPICS — lifecycle and send path are TRANSPORT's for every topic; payload vocabulary has a named owner; RLS is DATA's alone
  cs:<couple_id>                  payload TRANSPORT   | server-write-only
  cl:<couple_id>                  payload PRESENCE    | couple-writable, gated on reciprocal share_presence
  ch:<couple_id>:<recipient_uid>  payload MESSAGING   | read by that user, written only by their partner (typing)
  dev:<user_id>:<device_id>       payload PUSH        | server-write-only
  rtc:<call_id>                   payload CALLING     | the two parties
  rt:<couple_id>:<session_id>     payload FEATURE     | behind the SESSION-class lint allowlist
  realtime.messages RLS           -> DATA, sole owner. Four policies, each a single call to realtime_topic_allowed(topic, verb),
                                     one migration per topic-vocabulary generation, all authored by data.
  DB_POOL_SIZE >= 20              -> DATA (dashboard prerequisite, recorded, read back via Management API as a conformance expectation)

GRANTS AND PRIVILEGES
  Every GRANT and REVOKE in the project -> DATA, table level only. No column-level grant or revoke exists anywhere
  (pg_attribute.attacl IS NULL for every column in public, asserted in CI and every 60 s in production).
  No other domain may issue one. crypto's append-only assertions stay, restated at table level.

COST MODEL
  The single composed model -> DATA (§Cost). Every other document quotes it by reference and states no total of its own.

# Remaining conflicts

Six things my resolutions do not close. Each is stated with what it would take to close it.

1. THE 8% PEAK-CONCURRENCY ASSUMPTION IS UNMEASURED AND EVERY NUMBER IN ALL EIGHT DOCUMENTS RESTS ON IT. presence.md marks it INFERRED in its own text; transport.md's Stage 0 exists specifically to replace it with a measurement. For a couples app, where both partners are active in the same evening window, the real figure could plausibly be 2x. At 2x, the 10,000-user connection line goes from 800 to 1,600 (still inside Pro-no-cap) but the 50,000-user line goes from 4,000 to 8,000 against a hard 10,000 cap — which converts the declared app ceiling from '50k with 40% utilisation and real reconnect headroom' into '50k with 80% utilisation and none', i.e. the exact condition messaging.md refuses to support at 100k. I cannot reconcile this by decision. It is measurable in one release (transport Stage 0 plus messaging's canary), and the composed cost model and the 50,000-user ceiling should both be treated as provisional until it is measured. THIS IS THE SINGLE HIGHEST-VALUE UNKNOWN IN THE PROGRAMME.

2. SUPABASE PRESENCE HAS NO PUBLISHED BENCHMARK, SO ITS CEILING IS UNKNOWN. presence.md honestly withdrew its own '14x headroom' claim: Supabase publishes Broadcast benchmarks (250k concurrent, 800k+ msg/s) and publishes none for Presence, while its own architecture doc says a connecting user's state is replicated to every Realtime node — so Presence cost scales with churn x cluster size, not with a 2-member topic. presence.md's answer (ship concurrent-presence-key count as a metric from Stage E) is the right one and is the only one available. Verdict stands as 'unknown above a few thousand concurrent presence keys per tenant, evidence = absence of a published benchmark'. No decision I can make changes that.

3. THE COMPOSED COST MODEL IS ARITHMETIC, NOT MEASUREMENT, AND IT TRIPLES messaging.md's 50k FIGURE. The three source models priced disjoint event populations, so composing them is legitimate — but transport's interactive-canvas term (~500 events/user/day amortised, the largest and most variable line) rests on a '2 interactive sessions per week' guess that transport itself flags as having the widest error bar in its document. The composed 50k total of ~$4,200/mo carries roughly +/-2x uncertainty on its dominant line, and it is ~3x messaging.md's headline $1,540 for the same user count. I have made it the single quoted model because a single wrong-but-named number beats three mutually invisible ones, but the owner should know the planning figure for the declared ceiling is soft in the expensive direction, and that the fix is the same instrumentation as item 1.

4. THE BACKGROUND-ISOLATE WRITE PERMISSION IS AN UNRESOLVED CROSS-DOMAIN CONTRADICTION, AND IT WAS NOT IN MY BRIEF. client.md forbids the FCM background isolate from draining and from applying, and is internally split about it (§C treats it as a concurrent applier, §E forbids it, §M says violating the rule is safe). push.md §7.3/7.5/7.6 depends on it: catch-up on every push wake advancing cursor_seq, and a 3-second push_receipts ack with SharedPreferences buffering. If client.md wins, push.md's receipt table, its unreachable_suspected classifier and its cursor_seq send-suppression — the mechanism behind its '~12 pushes/user/day' figure — all silently degrade, and push's delivery SLI (accepted_not_delivered) loses its evidence source. MY RECOMMENDATION, offered but not decided because deciding it rewrites push's health machinery: client.md loses. The background isolate may perform exactly two writes, both idempotent and both bounded — one push_receipts ack and one greatest()-guarded cursor_seq advance — and may not drain the outbox and may not apply a sync page. That preserves messaging.md's actual requirement (its isolate is already budgeted to one page with a hard deadline and a sync_due marker) and preserves push's evidence chain. Someone must own this and close it before push Stage 2 or client C1, whichever ships first.

5. D0a STILL APPLIES UNREHEARSABLE SECURITY DDL TO PRODUCTION BEFORE STAGING EXISTS. data.md's own SERIOUS-4 repair is 'never touch prod before staging has proven the change', and D0a is the one change in the ten-stage plan that violates it — hand-applied RLS and privilege DDL on the five tables with no DDL at all (cycle_events, cycle_settings, love_reasons, care_nudges, app_secrets), whose client read/write contracts nobody has written down, and three of which transport.md records may have live subscriptions delivering nothing right now. Enabling RLS with a wrong or missing policy on a client-read table returns zero rows to every user with NO ERROR — the exact 'app looks alive and silently discards' failure the design names elsewhere as the worst shape. My resolutions inherit this ordering and add D1a next to it. The repair is cheap and I recommend it without having authority over the stage plan: dump first (read-only, free), stand up staging, test the fix there, then apply to prod, then re-dump for the baseline. That costs one extra dump and removes the hazard entirely. It is not reconciled because the current documents do not order it that way and nobody has taken the decision.

6. client.md's INVARIANT 1 IS NARROWED RATHER THAN SATISFIED, AND THE NARROWING IS A REAL WEAKENING. 'No RPC accepts a bigint position naming a read location, ENFORCED SERVER-SIDE' is true only for chat. transport's catch-up is a bigint range read (couple_stream WHERE pos > local_cursor), its liveness RPC takes applied_pos, its compaction floor is a client-reported integer, and it has a fast path doing client arithmetic on a socket-delivered integer (pos == local_cursor + 1); push's fetch_since takes p_cursor bigint and push_devices.cursor_seq is self-reported. Building the token chain for the other ~8 collections is a large new server surface that no sibling ships and that the client's own §0 prerequisite table does not ask for. I have narrowed the invariant to the socket rule, which is true everywhere and is what actually prevents divergence — correctness survives on the row lock, because position order is commit order by construction. WHAT IS LOST, stated plainly: for the non-chat streams there is no server-side clamp analogous to least(read_up_to, token.covered_through), so a buggy client CAN advance its own general-stream cursor past data it did not store, and the only backstop is stream_digest at cold start. That is a bounded, client-local, single-user failure — never cross-user, never a lost message on the server — but it is weaker than the invariant client.md claims, and the claim must be edited rather than left standing.
