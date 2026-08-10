# The Miles shared contract

**Authoritative.** Every one of the eight domain designs in `revised/` is a downstream reader of
this document. Where a design contradicts it, **this wins and that design is edited**.

It exists because eight architectures were designed in parallel and disagreed in eight places — one
of them fatal to a sibling. Without a single place that fixes who owns what, the next domain design
reintroduces the same class of conflict.

The machine-checkable half lives in the repo as data tables (`stream_registry`, `cron_job_manifest`,
`realtime_topic_registry`, `table_owner`, `bucket_map`) with a conformance expectation over each, so
drift is detected rather than discovered.

---

## Decisions

Eight cross-domain conflicts, resolved. Full reasoning in `RECONCILIATION.md`; the corrections that
verification forced are in `RECONCILIATION-REPAIRS.md` and are already folded in below.

| # | Decision |
|---|---|
| **R1** | ONE allocator ROW per couple holding TWO independent dense counters, incremented in ONE UPDATE under ONE row lock held to COMMIT. couple_cursor(couple_id uuid pk, next_pos bigint not null default 0, chat_seq bigint not null default 0), fillfactor 70. - A chat stream-mutating operation executes:… |
| **R2** | The retirement is authoritative and the index is never created. Verified on disk: presence(couple_id) has no index today, so there is nothing to drop — the resolution is a NEGATIVE conformance expectation, not a migration. Column-by-column disposition, which no document currently states, decided… |
| **R3** | ALL FOUR BUCKETS ARE public = false, PERMANENTLY, IN EVERY END STATE INCLUDING POST-CRYPTO. crypto.md's public-bucket end state is withdrawn. There is exactly one bucket map, owned by data, and it never changes at crypto's cutover. Expectation rows, committed in the migration that creates each… |
| **R4** | THE BUDGET IS A DECLARED ALLOCATION OF EIGHT, NOT A COUNT OF TWO. A committed cron_job_manifest(jobname, schedule, owner_domain, reason) is the comparand; the conformance expectation is SET EQUALITY against it, so an unexpected job and a missing job both fail, and adding a job is a migration that… |
| **R5** | SOLE OWNERSHIP CONFIRMED: data. Bucket rows, bucket flags, storage.objects policies, the bucket map, the conformance expectations and the cutover sequence are data's, in D7. messaging.md, push.md and presence.md carry no bucket responsibility and their deferrals are correct rather than negligent.… |
| **R6** | THERE IS NO USER-COUNT TRIGGER. THE TRIGGER IS A STAGE. messages is HASH-partitioned on couple_id into 32 partitions in messaging Stage 1, unconditionally, while production holds one couple. data.md v1 is the wrong document and its row-count trigger is deleted, as data.md's own §Cost already… |
| **CLIENT-F2** | UN-SEND AND HIDE BECOME CONTROL ROWS ON THE CHAT STREAM, MIRRORING clear. The target's cseq is never touched. WHAT IS WRITTEN. messages.kind is extended to {text, image, video, voice, clear, redact, hide}. messages gains target_cseq bigint null and for_user uuid null. A control row is a real row in… |
| **GRANT-LANDMINE** | REMOVE THE MECHANISM, DO NOT GUARD IT. A COLUMN-LEVEL GRANT OR REVOKE IS FORBIDDEN ANYWHERE IN THE PROJECT. Column protection is a BEFORE trigger; secret columns become secret TABLES; neither is a privilege. PER SITE, with the replacement: - profiles.couple_id: drop the column ACL, `grant update on… |

### Corrections applied after verification

- **F1** — Split the revoke by verb and put the guard BEHIND the RPC replacement, all inside messaging Stage 1's single ACCESS EXCLUSIVE transaction, in this order. STAGE 1, one transaction: (1) create the 32 hash partitions, add cseq / target_cseq / for_user, extend…
- **F2** — Clause (d) is WITHDRAWN and replaced by the definition in corrected_canary. The governing change: the canary learns the ISSUED RANGE from the ALLOCATOR ROW and the DELETION FLOOR from a RECORDED WATERMARK, and infers neither from the rows. Contiguity of the…
- **F3** — WITHDRAW 'in ONE UPDATE' and WITHDRAW the RPC-body allocation statement. THE ALLOCATOR IS THE BEFORE INSERT TRIGGER ON THE STREAMED TABLE, AND NOWHERE ELSE. On messages it executes UPDATE couple_cursor SET value = value + 1 WHERE couple_id = NEW.couple_id AND…
- **F4** — The two-dense-counters DECISION HOLDS; the one-row FORM does not. couple_cursor becomes couple_cursor(couple_id uuid, counter_kind text, value bigint not null default 0, floor_pos bigint not null default 0, primary key (couple_id, counter_kind)) with…
- **F5** — That presentation is WITHDRAWN and transport.md's ordering is restored. Non-chat streamed tables backfill by (created_at, id); messages backfills by (seq, id) because seq is server-assigned. The general rule, restated so it cannot be misread: A BACKFILL…
- **F7** — TYPING STAYS ON cl:<couple_id>, which §5's own table already gates on reciprocal share_presence for both read and write. ch:<couple_id>:<recipient_uid> BECOMES SERVER-WRITE-ONLY and carries exactly two payloads, both written by a server trigger and neither…
- **F9** — DECIDED, one position space. call_signals is a streamed table carrying exactly one position, stream_pos, allocated from the 'stream' counter by the shared BEFORE INSERT allocator trigger, and registered in stream_registry with that position column and that…
- **F11** — DECIDED, and it splits, because the two writes are not the same kind of thing. CLIENT.MD LOSES EXACTLY ONE NAMED EXCEPTION: the FCM background isolate MAY perform one network write, a push_receipts ack carrying (fcm_message_id, ack_delay_ms, priority,…

**Corrected production canary**

PERMANENT PRODUCTION CANARY — replaces R1 invariant_after clause (d) in full. Runs as an ops_job dispatched by ops_tick (60 s), one indexed aggregate per predicate per run, per couple. It reads the ISSUED RANGE and the DELETION FLOOR from the allocator table only; it never infers either from the rows, and it never asserts row contiguity.

WHAT IT READS TO KNOW THE ISSUED RANGE. couple_cursor(couple_id, counter_kind, value, floor_pos) — one row per family per couple. head = value; floor = floor_pos. Contiguity OF THE ISSUED RANGE is not scanned: a counter whose only mutation is +1 in a single BEFORE INSERT allocator trigger cannot skip a value, so issued-range contiguity is a property of the allocator (F3), not of a scan. floor_pos is written greatest()-guarded in the SAME transaction as the deletion it records — by clear_conversation_everyone for 'chat', by couple_stream_compact for 'stream'.

FAMILY 1 — CHAT (messages.cseq, counter_kind='chat').
K1 ALLOCATOR IS AHEAD OF THE ROWS: value >= coalesce(max(messages.cseq), 0) for the couple. Reads one allocator row plus an index-only max on (couple_id, cseq). Catches a row that acquired a cseq without the allocator, and a counter that was reset.
K2 NO VALUE WAS ISSUED TWICE: assert as CATALOGUE facts, not scans, that unique(couple_id, cseq) and NOT NULL on cseq exist and are validated in pg_constraint. Catches the drop of the constraint, which is how a duplicate becomes possible at all.
K3 DENSITY ABOVE THE LIVE FLOOR: count(messages where couple_id = C and cseq > floor_pos) = value - floor_pos. This is the only row-counting predicate; it is issued-range contiguity restricted to the range in which rows are supposed to still exist. It is NOT row contiguity — below the floor rows are expected to be gone. Catches a hard DELETE with no control row and no floor write, which has no other observable.
K4 NOTHING SURVIVES BELOW THE FLOOR EXCEPT THE BLANKING SIGNAL, AND THE TWO RECORDS OF THE FLOOR AGREE: every surviving row with cseq <= floor_pos has kind='clear'; and floor_pos = coalesce(max(clear_through_cseq) over surviving kind='clear' rows, 0). Served by a partial index messages(couple_id, clear_through_cseq desc) where kind='clear'. Catches a partial delete that left content behind the blanking signal (a privacy failure, not only a bookkeeping one) and a floor written without a control row or the reverse.
K5 NO SILENT MUTATION: zero rows with deleted_for_everyone = true having no kind='redact' row whose target_cseq names them. This is the direct observable for 'the stream was mutated without allocating', and it is what makes K1-K4 an alarm about the invariant rather than an alarm about deletion.
K6 STRUCTURAL: both allocator rows exist for every couple; cseq IS NOT NULL holds as a table constraint.
WHY IT IS NOT RED ON THE SECOND CLEAR: after clear#1 at cseq K1 and clear#2 at cseq K2, floor_pos = K2-1 and clear#1's row survives at K1 <= floor with kind='clear'. K3 counts [K2, value] = value - (K2-1). K4 passes on the surviving clear row. Nothing opens. Committed negative tests: (i) two consecutive clears open nothing; (ii) one row hard-deleted with no control row and no floor write opens K3 at page severity within one tick.

FAMILY 2 — GENERAL STREAM (couple_stream.pos, counter_kind='stream'). Same shape, measured over (floor_pos, value].
S1 value >= coalesce(max(couple_stream.pos), 0) for the couple.
S2 the PK (couple_id, pos) exists and is validated — catalogue read, no scan.
S3 count(couple_stream where pos > floor_pos) = value - floor_pos.
S4 zero couple_stream rows at pos <= floor_pos. couple_stream carries no rows a compaction must preserve, so the prefix delete is clean and this is exact; floor_pos is what couple_stream_compact actually deleted through, not a recomputed min(applied_pos), which also turns sync_head's floor_pos into a single-row read.
S5 APPEND BYPASS, SAMPLED: for each table in stream_registry, zero entity rows with a NULL position column, and zero entity rows whose position is above floor_pos with no couple_stream row at that pos — evaluated over the 1,000 newest rows per registered table per run, the same sampling bound R3 uses for bucket_path_shape, because a full anti-join per tick is not affordable. This is the analogue of K5: it catches 'the row commits, is never advertised, and both clients report caught-up'.

Neither family's canary reads created_at, a client-supplied integer, or a device clock. Both open a named alert per predicate with a severity and an age, so an alarm names which predicate and which couple rather than reporting a hole.

---

## The contract

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

---

## Ownership — exactly one owner per resource

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

---

## Not closed by decision

Six things my resolutions do not close. Each is stated with what it would take to close it.

1. THE 8% PEAK-CONCURRENCY ASSUMPTION IS UNMEASURED AND EVERY NUMBER IN ALL EIGHT DOCUMENTS RESTS ON IT. presence.md marks it INFERRED in its own text; transport.md's Stage 0 exists specifically to replace it with a measurement. For a couples app, where both partners are active in the same evening window, the real figure could plausibly be 2x. At 2x, the 10,000-user connection line goes from 800 to 1,600 (still inside Pro-no-cap) but the 50,000-user line goes from 4,000 to 8,000 against a hard 10,000 cap — which converts the declared app ceiling from '50k with 40% utilisation and real reconnect headroom' into '50k with 80% utilisation and none', i.e. the exact condition messaging.md refuses to support at 100k. I cannot reconcile this by decision. It is measurable in one release (transport Stage 0 plus messaging's canary), and the composed cost model and the 50,000-user ceiling should both be treated as provisional until it is measured. THIS IS THE SINGLE HIGHEST-VALUE UNKNOWN IN THE PROGRAMME.

2. SUPABASE PRESENCE HAS NO PUBLISHED BENCHMARK, SO ITS CEILING IS UNKNOWN. presence.md honestly withdrew its own '14x headroom' claim: Supabase publishes Broadcast benchmarks (250k concurrent, 800k+ msg/s) and publishes none for Presence, while its own architecture doc says a connecting user's state is replicated to every Realtime node — so Presence cost scales with churn x cluster size, not with a 2-member topic. presence.md's answer (ship concurrent-presence-key count as a metric from Stage E) is the right one and is the only one available. Verdict stands as 'unknown above a few thousand concurrent presence keys per tenant, evidence = absence of a published benchmark'. No decision I can make changes that.

3. THE COMPOSED COST MODEL IS ARITHMETIC, NOT MEASUREMENT, AND IT TRIPLES messaging.md's 50k FIGURE. The three source models priced disjoint event populations, so composing them is legitimate — but transport's interactive-canvas term (~500 events/user/day amortised, the largest and most variable line) rests on a '2 interactive sessions per week' guess that transport itself flags as having the widest error bar in its document. The composed 50k total of ~$4,200/mo carries roughly +/-2x uncertainty on its dominant line, and it is ~3x messaging.md's headline $1,540 for the same user count. I have made it the single quoted model because a single wrong-but-named number beats three mutually invisible ones, but the owner should know the planning figure for the declared ceiling is soft in the expensive direction, and that the fix is the same instrumentation as item 1.

4. THE BACKGROUND-ISOLATE WRITE PERMISSION IS AN UNRESOLVED CROSS-DOMAIN CONTRADICTION, AND IT WAS NOT IN MY BRIEF. client.md forbids the FCM background isolate from draining and from applying, and is internally split about it (§C treats it as a concurrent applier, §E forbids it, §M says violating the rule is safe). push.md §7.3/7.5/7.6 depends on it: catch-up on every push wake advancing cursor_seq, and a 3-second push_receipts ack with SharedPreferences buffering. If client.md wins, push.md's receipt table, its unreachable_suspected classifier and its cursor_seq send-suppression — the mechanism behind its '~12 pushes/user/day' figure — all silently degrade, and push's delivery SLI (accepted_not_delivered) loses its evidence source. MY RECOMMENDATION, offered but not decided because deciding it rewrites push's health machinery: client.md loses. The background isolate may perform exactly two writes, both idempotent and both bounded — one push_receipts ack and one greatest()-guarded cursor_seq advance — and may not drain the outbox and may not apply a sync page. That preserves messaging.md's actual requirement (its isolate is already budgeted to one page with a hard deadline and a sync_due marker) and preserves push's evidence chain. Someone must own this and close it before push Stage 2 or client C1, whichever ships first.

5. D0a STILL APPLIES UNREHEARSABLE SECURITY DDL TO PRODUCTION BEFORE STAGING EXISTS. data.md's own SERIOUS-4 repair is 'never touch prod before staging has proven the change', and D0a is the one change in the ten-stage plan that violates it — hand-applied RLS and privilege DDL on the five tables with no DDL at all (cycle_events, cycle_settings, love_reasons, care_nudges, app_secrets), whose client read/write contracts nobody has written down, and three of which transport.md records may have live subscriptions delivering nothing right now. Enabling RLS with a wrong or missing policy on a client-read table returns zero rows to every user with NO ERROR — the exact 'app looks alive and silently discards' failure the design names elsewhere as the worst shape. My resolutions inherit this ordering and add D1a next to it. The repair is cheap and I recommend it without having authority over the stage plan: dump first (read-only, free), stand up staging, test the fix there, then apply to prod, then re-dump for the baseline. That costs one extra dump and removes the hazard entirely. It is not reconciled because the current documents do not order it that way and nobody has taken the decision.

6. client.md's INVARIANT 1 IS NARROWED RATHER THAN SATISFIED, AND THE NARROWING IS A REAL WEAKENING. 'No RPC accepts a bigint position naming a read location, ENFORCED SERVER-SIDE' is true only for chat. transport's catch-up is a bigint range read (couple_stream WHERE pos > local_cursor), its liveness RPC takes applied_pos, its compaction floor is a client-reported integer, and it has a fast path doing client arithmetic on a socket-delivered integer (pos == local_cursor + 1); push's fetch_since takes p_cursor bigint and push_devices.cursor_seq is self-reported. Building the token chain for the other ~8 collections is a large new server surface that no sibling ships and that the client's own §0 prerequisite table does not ask for. I have narrowed the invariant to the socket rule, which is true everywhere and is what actually prevents divergence — correctness survives on the row lock, because position order is commit order by construction. WHAT IS LOST, stated plainly: for the non-chat streams there is no server-side clamp analogous to least(read_up_to, token.covered_through), so a buggy client CAN advance its own general-stream cursor past data it did not store, and the only backstop is stream_digest at cold start. That is a bounded, client-local, single-user failure — never cross-user, never a lost message on the server — but it is weaker than the invariant client.md claims, and the claim must be edited rather than left standing.

---

## Residual after repair

NOT REPAIRED, BECAUSE NOT IN THE BRIEF — these remain open exactly as the verifier states them: F6 (profiles.avatar_url is a fourth rendered-URL column missed by R5's 'verified' enumeration, and the checked-in media-column list is the enumeration form GRANT-LANDMINE correctly argues always rots), F8 (Stage M's repo grep is not a fleet gate on a sideloaded app with 7 live .from('presence') call sites), F10 (three of data.md's own retention entries cannot satisfy the surviving enable-gate conditions), F12 (attacl predicate and D1a's own statement form), F13 (the admission test forbids its own 60 s dispatcher), F14 (§9's trigger list covers the six conflicts that were found, not their class), F15 (§9 creates five more unverified row-shaped comparands), F16 (mandatory expires_at on permanently policy-free internal tables). F14 is the one that matters to this pass: F9's 'why it cannot regress' depends on §9's registry set being extended to counters and position spaces of ANY scope. Until F14 is adopted, F9 is a correct decision with no anti-recurrence mechanism behind it — a future per-call or per-entity counter would pass every assertion in the contract exactly as calls.signal_seq did.

UNMEASURED NUMBERS THIS PASS INTRODUCES OR MOVES. (1) The typing billing multiplier. The +12% cost consequence of F7 is arithmetic under the contract's own rule ('self:false bills 2 on a per-recipient topic and 3 on a shared one'), but presence.md:335 prices typing on the SAME shared :live topic at x2. One of the two is wrong, neither is measured, and if self:false suppresses the echo's billing then F7 costs nothing at all. This is settled by one day of a two-device couple read against the Realtime usage counter, and it should be settled before data.md §Cost is rewritten — I have written the conservative direction into the repair and marked presence.md:335 superseded rather than resolving it. (2) push.md's ~12 pushes/user/day is provisional under F11's rule that cursor_seq advances only on the main isolate; its binding constraint (the 12-token/180 s collapsible bucket) does not depend on the decision, so the figure is bounded, but it is not re-derived. (3) The allocator lock hold for clear_conversation_everyone is argued to be bounded by one hash partition; that is an argument, not a measurement, and messaging.md's pgbench test 9 is what settles it. (4) F9 moves every ICE candidate onto couple_stream and the cs: doorbell — transport §I already decided that, but I could not find it priced in the composed cost model, and an ICE burst is ~10-20 appends per call for both members.

WEAKENED RATHER THAN RESTORED. F4's two-row split converts deadlock-freedom from a structural impossibility (one row, one lock) into an asserted property (CI: no function body takes both counter rows) plus a declared lock order. That is a real weakening and it is the price of un-coupling chat from calling; I judged the cross-domain blocking to be the worse exposure, but the assertion now has to hold forever.

NOT VERIFIED MECHANICALLY. Everything here is a document change. The on-disk facts I quote were checked directly (the four chat_repository insert sites and two select sites; the five server-side message mutation paths including delete_my_account, which no resolution named; the messages_update_member UPDATE policy; gen_random_uuid PKs on every streamed entity table; exactly one sequence-backed column project-wide). Nothing else was run: no migration, no canary query, no test. The canary above, the four replaced RPC bodies, the two allocator triggers and the Stage-1 transaction are unimplemented and untested, and the Stage-1 transaction now carries more DDL under ACCESS EXCLUSIVE than messaging.md sized it for — the added work is metadata-only and should not move the ~30 s / 5M-row estimate, which is a claim I did not measure.

CANNOT BE REPAIRED WITHOUT REDESIGN. None of the eight items in this brief. The nearest thing is F7's cost: preserving BOTH the privacy predicate and the per-recipient billing would need a privacy-gated per-recipient typing topic, which is a fourth always-on channel and a new topic class, i.e. a redesign of §5 rather than a repair — so I took the read-gated shared topic and paid for it in the cost model instead.
