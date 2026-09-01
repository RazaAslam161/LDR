## Home dashboard  [risk: high]
- purpose: Landing tab: partner's status (online, mood, their local time, current screen), check-in snap, location card, cycle card, Reach button, half-paired invite-code recovery.
- files: E:/LDR/mobile/lib/features/home/home_screen.dart (tab 0 of E:/LDR/mobile/lib/features/shell/app_shell.dart); check-in camera via context.push('/app/rapid-camera', extra:{'mode':'checkin'}) → E:/LDR/mobile/lib/core/router.dart:160-169
- tables: presence (read partner row, write own), profiles, couples, pairing_invites (activePairingInvite / create_pairing_invite RPC), storage bucket couple_media (checkins/<uid>_<ms>.jpg, PUBLIC bucket, getPublicUrl at home_screen.dart:130)
- transport: partnerPresenceProvider: postgres_changes on `presence` filtered by couple_id, PLUS an unconditional 15s Timer.periodic full-row refetch (presence_service.dart:436) PLUS an 800ms debounce refetch on every event. No push.
- how it works: While Home is mounted AND foregrounded, _startLocationUpdates() runs a 15s Timer that calls LocationService.shareCurrent(coupleId) — which does a SELECT on presence (fetchMine) to re-read the saved mode, then a device GPS read, then (mode!='off') a reverse-geocode via the OS Geocoder, then an UPSERT on presence. Home also calls Geolocator.getLastKnownPosition() every 15s for its own distance readout. Online-ness is not the DB is_online flag: Presence.isTrulyOnline compares app_last_active_at (stamped server-side by a BEFORE trigger, presence_server_time.sql) against ServerClock.now() with a 45s window, fed by a 30s foreground heartbeat in main.dart:203. Check-in: rapid camera returns a baked File, Home uploads it to couple_media and writes the public URL to presence.checkin_photo_url.
- weaknesses: Location sharing is foreground-and-Home-only: leaving the Home tab (not even the app) cancels the timer, so the partner's map silently freezes while the app is still open on Chat. Two DB round-trips + one geocode per user per 15s just to publish a position. didChangeAppLifecycleState cancels on any non-resumed state but only restarts from Home's resume. The public couple_media check-in URL never expires and the couple_id is the first path segment (documented as an attack surface in hardening_2026_08.sql:25).
- scale reason: Per active user with Home open: 4 presence SELECTs + 4 presence UPSERTs + 4 geocodes per minute for location, plus 4 presence SELECTs/min from the provider poll, plus 2 heartbeat upserts/min. That is ~14 DB ops/user/minute at idle before anyone touches anything; 1,000 concurrent users ≈ 14k writes+reads/min against one Postgres row set with replica identity full and realtime fan-out on every write.

## Partner location card / 2D map / 3D map  [risk: high]
- purpose: Show the partner's live position, distance, 'updated Xs ago', and a full-screen 3D satellite view.
- files: E:/LDR/mobile/lib/features/home/partner_location_card.dart, E:/LDR/mobile/lib/features/home/location_map_screen.dart (route /app/location-map), E:/LDR/mobile/lib/features/home/map_3d_screen.dart (pushed directly, no route)
- tables: presence.latitude/longitude/location_accuracy/location_label/location_sharing_mode/location_updated_at
- transport: Consumes partnerPresenceProvider only (postgres_changes + 15s poll). location_map_screen adds its own 15s Timer for the user's OWN last-known position.
- how it works: flutter_map with raster tiles from https://tile.basemaps.cartocdn.com/rastertiles/voyager (partner_location_card.dart:236, location_map_screen.dart:200) — CARTO's free public basemap CDN, no API key, no account. Map3DScreen builds an HTML string and loads it into a WebView with JavaScriptMode.unrestricted; that page pulls MapLibre GL JS from https://unpkg.com/maplibre-gl@4.7.1 and tiles from ArcGIS World_Imagery, s3.amazonaws.com/elevation-tiles-prod and tiles.openfreemap.org (map_3d_screen.dart:77-98).
- weaknesses: Four unpaid third-party endpoints with no key, no contract, and no fallback; CARTO and openfreemap both rate-limit and their ToS forbid heavy commercial use. The 3D map executes remote JavaScript fetched at runtime inside an unrestricted WebView — a supply-chain injection path straight into an app whose whole premise is hiding. Precise coordinates are stored in plaintext in the presence table (not encrypted, unlike the Closer module).
- scale reason: Free tile CDNs will throttle or block the app's User-Agent long before thousands of users; the map is on the HOME screen, so every session hits it. Requires migrating to a paid tile provider (or self-hosting) before launch.

## Care reminders (nudges)  [risk: high]
- purpose: Send the partner a preset or custom 'take care' nudge; the recipient taps Done and the sender sees the acknowledgement.
- files: E:/LDR/mobile/lib/features/care/care_screen.dart (route /app/care, drawer), E:/LDR/mobile/lib/features/care/care_repository.dart
- tables: care_nudges (couple_id, from_user, kind, message, created_at, acknowledged_at) — THIS TABLE HAS NO DDL ANYWHERE IN E:/LDR/supabase. Only a trigger references it (20260628_care_call_push.sql:39-42). Its columns, indexes and RLS policies exist only in the live database.
- transport: postgres_changes on care_nudges filtered by couple_id (care_repository.dart:71-88) wrapped in ManagedSubscription; plus FCM: an AFTER INSERT trigger calls notify_care() → pg_net POST → reach-notify edge function → data-only FCM message type='care' → firebaseMessagingBackgroundHandler shows a generic 'Reminders' notification.
- how it works: Plain INSERT of a plaintext message row; acknowledge() is a client-side UPDATE stamping acknowledged_at with the DEVICE clock (care_repository.dart:57). The screen refetches the last 50 rows on every realtime event (no incremental apply). Send errors are swallowed by an empty catch (care_screen.dart:93) so a failed insert produces no toast and no error — it just silently does nothing.
- weaknesses: The push notification carries no text at all (disguise requirement, reach_notifications.dart:199-223) — the whole nudge is 'Take your medicine' and the recipient sees a blank generic alert, so the feature does not deliver what it promises unless the app is opened. Any couple member can UPDATE acknowledged_at on a nudge they sent (RLS unknown/unverifiable). No rate limit — the custom-message dialog is an unthrottled plaintext write path to the partner's notification tray. No DDL means no staging environment can run this feature at all.
- scale reason: Backend object is not reproducible from source (no DDL, no RLS in repo), full 50-row refetch on every event, and an unbounded per-message pg_net → edge function → FCM chain with no batching or throttle.

## Rituals  [risk: medium]
- purpose: Advertised as scheduled recurring couple moments ('goodnight', 'goodmorning', 'weekly high/low', custom) delivered at a chosen time.
- files: E:/LDR/mobile/lib/features/rituals/rituals_screen.dart (route /app/rituals, drawer), create_ritual_screen.dart, ritual_repository.dart
- tables: rituals (schema.sql:70-78: couple_id, type, cron, message, deliver_at, delivered) + index rituals_pending_idx on (delivered, deliver_at)
- transport: NONE. No realtime channel, no push, no cron job, no edge function.
- how it works: CreateRitualSheet builds deliverAt as DateTime(today, chosen HH:MM) in device local time (create_ritual_screen.dart:38-44), converts to UTC and INSERTs. RitualRepository.list() reads them back ordered by deliver_at. That is the entire feature. The repository comment states it outright (ritual_repository.dart:6-9): 'v1 does not schedule push notifications'. Nothing ever sets delivered=true; the `cron` column is never written.
- weaknesses: This is a feature that never fires. The UI says 'This ritual will no longer be scheduled' on delete and renders a 'delivered' badge that can never appear. rituals_screen.dart:273-274 prints DateFormat(deliverAt.toLocal()) TWICE and labels the second copy '· HH:MM their time' — the partner's timezone is never applied, so the 'their time' readout is always wrong for any couple not in the same zone (i.e. the entire target market). Picking a time earlier than now creates a row already in the past.
- scale reason: Harmless today because nothing runs, but the moment delivery is implemented it needs a scheduler that scans rituals across all couples per minute and honours per-user timezones — an architecture that does not exist anywhere in this codebase (there is no worker, no pg_cron job for rituals, no queue).

## Games hub  [risk: none]
- purpose: Menu of three couple mini-games.
- files: E:/LDR/mobile/lib/features/games/games_screen.dart (route /app/games, drawer)
- tables: none
- transport: none
- how it works: Static list of three cards routed to /app/games/truth-dare, /app/games/would-you-rather, /app/games/never-have-i-ever. Card copy switches on contentLanguageProvider (English / Roman Urdu).
- weaknesses: The hub labels Truth or Dare `synced: true` (LIVE badge) and marks Would You Rather / Never Have I Ever `synced: false` — but all three sync over broadcast channels. The badge is decorative and wrong. No age gate on this route despite Truth or Dare carrying an explicit 'Spicy' tier (see below).
- scale reason: Pure static UI.

## Truth or Dare (synced)  [risk: medium]
- purpose: Turn-based Truth or Dare with three heat tiers, same card on both phones.
- files: E:/LDR/mobile/lib/features/games/truth_dare_screen.dart, truth_dare_deck.dart, game_content.dart (route /app/games/truth-dare)
- tables: NONE — nothing about a game is ever persisted server-side. Local state only: SharedPreferences keys `nrb_td_<type>_<tier>_<lang>` via NoRepeatBag.
- transport: Supabase Realtime BROADCAST channel `game_td:<coupleId>`, events 'state' and 'sync' (truth_dare_screen.dart:56-67). Ephemeral — nothing is stored, nothing is replayed. No push.
- how it works: Whole game state (turn uid, round, tier, card {type,tier,index}) lives in each client's setState and is re-broadcast on every mutation. On subscribe, a 900ms timer sends a 'sync' ping; whoever is already started re-broadcasts their state. Cards travel as a POOL INDEX, not text, so each phone renders from its own language pool (localiseTD). Pools are built combinatorially (5 openers × 21 cores per tier per type per language, game_content.dart:303-312).
- weaknesses: Requires both partners in the same screen at the same instant on a live websocket — no state survives a backgrounded app, a dropped socket, or one partner arriving 10 seconds later. Two clients both tapping Start produce two conflicting turn owners with no arbitration. The cross-language index contract is an unenforced invariant: if anyone adds an English opener without an Urdu one, every card silently desyncs. The broadcast channel is NOT a private/authorized channel (no RealtimeChannelConfig anywhere in the client, no realtime.messages RLS in any .sql) — any authenticated user who knows a couple_id can join `game_td:<coupleId>` and read or inject cards. couple_id is not secret; it is the first path segment of every public couple_media URL. The 'Spicy' tier is reachable at /app/games/truth-dare with no isAdult check and no modest_mode check, unlike the Closer tab which gates on both (app_shell.dart:215-221).
- scale reason: Broadcast is cheap per message but unauthorized channels are a cross-couple confidentiality hole that gets worse with user count, and NoRepeatBag persists every dealt SENTENCE (not an index) into SharedPreferences — thousands of strings across 12 tier/type/language bags.

## Never Have I Ever / Would You Rather (synced card game)  [risk: medium]
- purpose: One card on both phones, either partner can deal the next, with a live answer strip.
- files: E:/LDR/mobile/lib/features/games/synced_card_game_screen.dart (routes /app/games/never-have-i-ever, /app/games/would-you-rather)
- tables: none. SharedPreferences bags `nrb_card_<deck>_<lang>`.
- transport: Broadcast channel `gcard:<deckKey>:<coupleId>`, events 'card' and 'sync'. Ephemeral, no persistence, no push.
- how it works: Identical shape to Truth or Dare: draw locally from NoRepeatBag, broadcast {from, text, index}, receiver looks the index up in its own language pool and marks it seen locally so the no-repeat bag stays roughly shared.
- weaknesses: Same as Truth or Dare: both-online-simultaneously requirement, unauthorized public broadcast channel keyed on a guessable couple_id, no server state. The no-repeat 'shared' bag is only shared while both are on screen — a card dealt while the partner is away is never retired on their device.
- scale reason: Same unauthorized-broadcast exposure; message volume is low (one per deal).

## In-game chat panel  [risk: medium]
- purpose: Live answer strip embedded in every game.
- files: E:/LDR/mobile/lib/features/games/game_chat_panel.dart
- tables: NONE — messages are never stored anywhere, not even locally.
- transport: Broadcast channel `gchat:<gameKey>:<coupleId>`, event 'msg'.
- how it works: Text goes into an in-memory List<_GameMsg> and out as a broadcast payload {from, name, text}. Closing the screen destroys the conversation.
- weaknesses: Real user messages (including the sender's display name) travel over a public, unauthorized broadcast channel keyed only on couple_id — readable by any authenticated user who guesses/derives the id. Nothing is delivered to a partner who is not on that exact screen at that exact moment; there is no 'you missed this'. The empty-state hint is hardcoded Roman Urdu regardless of the language toggle.
- scale reason: Confidentiality of plaintext user content on an unauthenticated channel; volume itself is small.

## Pick For Us (consent dice)  [risk: low]
- purpose: Three-tier 'let the dice decide' with per-tier dual consent.
- files: E:/LDR/mobile/lib/features/closer/pick_for_us/pick_for_us_screen.dart (route /app/closer/pick-for-us), pick_for_us_repository.dart
- tables: dice_rolls (couple_id, rolled_at, tier, result_tags[]), dice_tier_consents (couple_id, tier, user_id, granted, granted_at) — both in intimacy_tables.sql with couple-scoped RLS.
- transport: NONE. No realtime channel, no push.
- how it works: On open, fetchConsents() reads every dice_tier_consents row for the couple into a {tier → {uid → bool}} map; a tier is 'unlocked' only if both uids are true. Tapping consent upserts my row then re-reads the whole consent set and returns the pair. Rolling picks a random tag per enabled tier client-side (Random in the repository) and INSERTs a dice_rolls row.
- weaknesses: Consent is polled, not pushed: partner A granting consent is invisible to partner B until B closes and reopens the screen, so the 'waiting for them' state can be stale indefinitely. dice_rolls has no author column and the RLS is couple-wide, so either partner can insert rolls at any tier regardless of the consent state (consent is enforced only in the Dart UI). Randomness is per-device, so the two phones never see the same roll unless one of them refetches.
- scale reason: Tiny write volume; the defects are correctness/consent, not throughput.

## Rapid camera (in-app camera)  [risk: medium]
- purpose: Fast camera with live filters, pinch zoom, screen-flash selfies, hold-to-record video, one-tap send to chat, and 'Use Photo' return mode for the Home check-in.
- files: E:/LDR/mobile/lib/features/chat/rapid_camera_screen.dart (route /app/rapid-camera; nav index 2 in app_shell.dart:296-303 and Home's check-in), camera_bake.dart, camera_filters.dart, camera_filter_painter.dart
- tables: messages (via ChatRepository), storage couple_media (images, PUBLIC bucket), storage couple_intimate (videos, private + signed URLs)
- transport: After upload, ChatSendQueue fires ChatBroadcastService.broadcastImage on the chat broadcast channel as a fast path; the durable delivery is the messages INSERT + its postgres_changes echo + the notify_message() → reach-notify FCM push.
- how it works: Explicit Permission.camera/microphone request before creating the controller (with MilesApp.systemOverlayActive set so the disguise cover does not fire). Controller ladder veryHigh → high with a 12s init timeout. Capture writes the plugin's JPEG; if the filter is 'none' and no mirror is needed the sensor JPEG is shipped untouched, otherwise a compute() isolate decodes, mirrors by raw row reversal, applies the 4×5 matrix/blur/overlay/grain and re-encodes at q88 capped at 1920px (camera_bake.dart). Send hands the File to the in-memory ChatSendQueue singleton and pops immediately.
- weaknesses: ChatSendQueue is a RAM-only singleton (chat_send_queue.dart:51) — a pending upload does not survive process death, and Android will kill a backgrounded Flutter process mid-upload; the photo and its temp file are then gone with no record and no retry. Failed sends are only recoverable while the process lives. Images land in a PUBLIC bucket with a never-expiring URL (getPublicUrl), while videos correctly use the private bucket — an inconsistent privacy posture in an app built around concealment.
- scale reason: Every photo is a full-resolution JPEG upload to Supabase Storage with no server-side resize/derivative pipeline and no CDN cache policy in the repo; storage cost and egress scale linearly with users and nothing ever prunes couple_media except explicit message deletion.

## Media viewer  [risk: low]
- purpose: Full-screen pinch-zoom viewer for chat photos and the Home check-in snap, with a 'save to vault' button.
- files: E:/LDR/mobile/lib/features/chat/media_viewer.dart; opened from chat_screen.dart:1620 and home_screen.dart:350
- tables: none directly; writes via SaveMediaService → personal_vault_items
- transport: none
- how it works: A plain Image.network(url) inside an InteractiveViewer with a Hero. No auth header, no signed URL — it only works because couple_media is a public bucket.
- weaknesses: Uses raw Image.network rather than the app's own cached NetImage, so every open re-downloads the full-resolution original and decodes it at source size into the image cache (NetImage exists precisely to avoid this, net_image.dart:26-40). It cannot display anything from the private couple_intimate bucket. senderName defaults to the literal string 'a message', which becomes the vault label ('Photo from a message').
- scale reason: Client-side memory/bandwidth waste per view, not a backend bottleneck.

## Saved media / Personal Vault  [risk: medium]
- purpose: PIN- or biometric-locked personal space for private notes and 'saved' chat media, advertised as writing zero bytes to the device.
- files: E:/LDR/mobile/lib/features/vault/vault_gate_screen.dart (route /app/vault), vault_screen.dart, vault_repository.dart, pin_pad.dart, E:/LDR/mobile/lib/core/services/save_media_service.dart, core/widgets/save_media_button.dart
- tables: personal_vault_items (private_vault.sql:26-36, owner-only RLS), vault_pin (bcrypt hash + failed_attempts + locked_until); RPCs set_vault_pin / verify_vault_pin / has_vault_pin
- transport: none — plain fetch on open.
- how it works: 'Saving' media does NOT copy any bytes: it inserts a row whose `content` is either the public couple_media URL verbatim or the string 'intimate:<storagePath>', with the human label crammed into the `media_url` column (vault_repository.dart:87-94). Opening an item resolves a fresh signed URL for the intimate path, then hands the URL to launchUrl(..., LaunchMode.externalApplication) — i.e. the system browser (vault_screen.dart:92-93). PIN verification is server-side bcrypt with a 5-try/15-minute lockout; the gate re-locks on every non-resumed lifecycle state.
- weaknesses: A saved item is a pointer the OTHER partner can revoke: delete_message_for_everyone and clear_conversation_everyone delete the storage object (chat_media_cleanup.sql:25-27, 44-50), so the vault entry silently 404s afterwards — the promise 'saved forever, privately' is not kept. Opening saved media launches the EXTERNAL BROWSER, dumping a private (often intimate) image into Chrome's history/cache on a phone whose whole point is that the app is disguised — this defeats both the PIN gate and the disguise. The 'label' is stored in the media_url column, so the schema no longer means what it says. couple_media URLs are public and permanent, so vault 'privacy' for photos is a UI convention only.
- scale reason: Low write volume, but the dangling-reference model means vault contents rot at a rate proportional to message deletion, and there is no reference counting or copy-on-save anywhere.

## App lock (biometric/PIN gate over the whole app)  [risk: low]
- purpose: Require fingerprint/face/PIN to open the app.
- files: E:/LDR/mobile/lib/core/services/app_lock.dart, core/widgets/lock_screen.dart, core/widgets/app_lock_pin_sheet.dart; toggled in settings_screen.dart:85-110
- tables: none — SharedPreferences keys `app_lock_enabled`, `app_lock_pin_hash`
- transport: none
- how it works: local_auth for biometrics (MainActivity extends FlutterFragmentActivity so the prompt works), plus a mandatory 4-digit fallback PIN stored as sha256('miles-applock::' + pin) in SharedPreferences (app_lock.dart:36-48).
- weaknesses: Unsalted, un-stretched SHA-256 of a 4-digit PIN in plaintext SharedPreferences XML: the whole 10,000-entry rainbow table is computable in milliseconds from any device backup or rooted read. No attempt counter and no lockout on the app-lock PIN (unlike the vault PIN, which is bcrypt + server-side lockout). The two PIN systems are unrelated and a user can end up with two different 4-digit PINs.
- scale reason: Entirely local; a security defect rather than a scaling one.

## Cycle tracking  [risk: high]
- purpose: Period logging + prediction for the female partner, with an opt-in gentle summary card for the male partner.
- files: E:/LDR/mobile/lib/features/cycle/cycle_screen.dart (route /app/cycle, drawer), cycle_repository.dart, partner_cycle_card.dart (embedded in Home)
- tables: cycle_settings (user_id, couple_id, avg_cycle_length, avg_period_length, share_with_partner, tracking_enabled, on_period_now, updated_at) and cycle_events (user_id, couple_id, type, event_date, created_at) — NEITHER TABLE HAS DDL IN E:/LDR/supabase. Sensitive health data whose RLS posture cannot be verified from source.
- transport: postgres_changes on `cycle_events` with NO couple_id filter — cycle_screen.dart:66-74 and partner_cycle_card.dart:40-48 both subscribe to the whole table and simply re-run _load() on any event. No push.
- how it works: setOnPeriod() inserts a cycle_events row with event_date = the DEVICE's local calendar date (cycle_repository.dart:237) and upserts on_period_now on cycle_settings. All prediction is client-side: CyclePrediction.compute averages start-to-start gaps (10<gap<90) and derives phase from dayOfCycle vs (cycleLen-14). The male view fetches the partner's settings, and only if share_with_partner is true fetches her events and derives a detail-free card.
- weaknesses: Backend tables do not exist in version control — the app's most sensitive data has no reviewable RLS. Both subscriptions are unfiltered table-wide listeners (correctness depends entirely on RLS filtering realtime, which cannot be confirmed here). cycle_screen's _subscribe uses the known-bad `_channel?.unsubscribe()` then immediately re-`channel()` with the same topic on every realtimeResumed — the exact duplicate-topic 'joined but dead' bug that ManagedSubscription was written to fix and which the rest of the app now uses. Views are gated on profile.gender: a user who never sets gender falls into the male branch and sees the 'partner' view of themselves. Dates come from the device clock, so a wrong clock silently corrupts the history.
- scale reason: Unfiltered postgres_changes subscriptions on a table with thousands of users mean Realtime evaluates RLS per subscriber per change; two such subscriptions are mounted (Home card + screen). Combined with no DDL/no index guarantees and no server-side prediction, this is the module least ready for multi-tenant load.

## Love notes (pooled)  [risk: none]
- purpose: Serve the male partner a never-repeating romantic paragraph to edit and send into chat.
- files: E:/LDR/mobile/lib/features/cycle/love_notes_pool.dart, love_note_preview_sheet.dart; invoked from cycle_screen.dart:495-520
- tables: none server-side — sends land in `messages` via ChatRepository.sendText. Local state in SharedPreferences (`love_notes_sent_indices`, `love_notes_shuffle_order`, `love_note_recipient_name`).
- transport: n/a (the resulting chat message uses the normal chat path).
- how it works: 250 hardcoded const Dart strings (Roman Urdu/Punjabi, husband→wife voice) compiled into the APK. LoveNotesTracker keeps a shuffled index order and a used-index list in SharedPreferences, reshuffling once the pool is exhausted. 155 of the notes carry a {name} token filled by renderLoveNote from a locally stored recipient name.
- weaknesses: The entry point is DEAD: FeatureFlags.pooledLoveNotes is false (feature_flags.dart:15) so the button never renders — but the 250-paragraph pool still ships in every APK. The content is one specific couple's private register with hardcoded pet names ('begum', 'churail', 'bandri', 'chuii') and no localisation, and is gender-hardcoded husband→wife. The used-index list grows to 250 entries in SharedPreferences per device.
- scale reason: Flag-disabled dead code with zero backend footprint; the only cost is APK size and the product risk if the flag is ever flipped as-is.

## Breath sync  [risk: high]
- purpose: Shared 4-7-8 breathing pacer — both phones pulse in unison.
- files: E:/LDR/mobile/lib/features/breath/breath_sync_screen.dart (route /app/breath, drawer)
- tables: breath_events (breath_events.sql: couple_id, user_id, started_at bigint ms-since-epoch, created_at) with a pg_cron nightly delete of rows older than 1 day.
- transport: postgres_changes INSERT on breath_events filtered by couple_id, via ManagedSubscription. No push.
- how it works: Tapping Begin INSERTs a row carrying the DEVICE's DateTime.now().millisecondsSinceEpoch. The partner's client receives the insert, computes elapsedMs = its own DateTime.now() minus the received started_at, ignores the event if elapsedMs > one full cycle (19s), otherwise starts its animation at that offset. At the end of every cycle _beginCycle() recurses — inserting ANOTHER row — so an active session writes one DB row per user per 19 seconds indefinitely, and each of those rows fans out over Realtime to the partner, who restarts their own cycle (and their own recursive insert).
- weaknesses: Sync is computed from two unsynchronised device clocks even though ServerClock exists and is used elsewhere — a phone more than 19 seconds off will discard every partner event and never sync, silently, with the UI still saying 'they'll feel it the moment they arrive'. There is no Stop broadcast: pressing Stop cancels only the local timer, so the partner keeps breathing alone. The insert-per-cycle design uses a durable Postgres table for what is a pure ephemeral tick (the file's own comment calls it 'a tiny table so the realtime channel can fan out').
- scale reason: ~3 INSERTs/user/minute plus a Realtime fan-out and a full trigger/WAL cycle per tick, for data with a 19-second useful life, retained a full day. A broadcast channel would cost zero writes. 1,000 concurrent breathers = 3,000 durable writes/min.

## Reach (hold-to-reach alert)  [risk: high]
- purpose: Send a partner an urgent full-screen 'reaching for you' alert that can wake their screen.
- files: E:/LDR/mobile/lib/features/reach/reach_button.dart (on Home), reach_repository.dart, reach_overlay_screen.dart; app-wide listener in app_shell.dart:112-182; E:/LDR/mobile/lib/core/services/reach_notifications.dart; E:/LDR/supabase/functions/reach-notify/index.ts
- tables: reach_events (couple_id, from_user, created_at, acknowledged_at, expires_at default now()+30s; replica identity full; in the supabase_realtime publication). reach_pulses ALSO EXISTS (reach_pulses.sql, with its own pg_cron cleanup) but NO CLIENT CODE EVER READS OR WRITES IT — a dead table.
- transport: Both. Foreground: postgres_changes INSERT on reach_events filtered by couple_id, subscribed app-wide in AppShell. Background: AFTER INSERT trigger notify_reach() → pg_net POST → reach-notify edge function → OAuth2 service-account JWT → FCM v1 data-only message with ttl 30s → firebaseMessagingBackgroundHandler builds a full-screen-intent notification.
- how it works: INSERT one row; both delivery paths are de-duplicated in AppShell._showReach by reach id. Acknowledge is a client UPDATE stamping acknowledged_at.
- weaknesses: AppShell._onReach drops any event where !e.isActive, and isActive compares the SERVER-generated expires_at against the local DateTime.now() (reach_repository.dart:29) — a device clock running 30+ seconds fast discards every reach it receives, silently, forever. The 30s cooldown is client-only, held in widget state (reach_button.dart:20-28), so it resets on navigation and is trivially bypassed via the REST API — an unrate-limited path to wake someone's screen. profiles.fcm_token is a single column, so a second device overwrites the first and only the newest device is ever notified. FCM ttl is 30s, so a doze-stuck delivery is discarded. reach-notify returns 200 on every failure to avoid retry storms, and pg_net swallows responses, so silent delivery failures are only visible in net._http_response.
- scale reason: Every reach is a Postgres INSERT + trigger + pg_net HTTP call + edge function cold start + Google OAuth token exchange (the token is minted per invocation, never cached, functions/reach-notify/index.ts:51-90) + FCM send. That is a full OAuth round trip per notification for every reach, care nudge, call and CHAT MESSAGE in the system — the single hardest bottleneck in the push path.

## Settings  [risk: low]
- purpose: Profile, avatar, gender, timezone, content language, disguise, location sharing mode, FSI permission, modest mode, biometric app lock, remove partner, sign out, delete account.
- files: E:/LDR/mobile/lib/features/settings/settings_screen.dart (route /app/settings)
- tables: profiles (display_name, status_message, gender, timezone, avatar_url), couples.modest_mode, presence.location_sharing_mode, storage couple_media (avatars/), RPCs leave_couple() and delete_my_account()
- transport: none; reads sessionProvider and re-runs loadProfile() after each write.
- how it works: Direct table writes through SupabaseRepository plus two SECURITY DEFINER RPCs. Avatar upload goes to the PUBLIC couple_media bucket with getPublicUrl. Location mode writes presence.location_sharing_mode and then does one immediate shareOnce. Delete account clears the FCM token, calls delete_my_account() and signs out.
- weaknesses: Modest mode is a single boolean on `couples` written by whichever partner flips the switch (supabase_repository.dart:128-135), so 'This reveals the intimacy module for both of you' and the schema comment 'both must opt out to reveal it' (intimacy_additions.sql) are both false — one partner unilaterally reveals it for the other. There are NO notification preferences anywhere: a user cannot mute reaches, care nudges or messages. There is no cycle-tracking entry (it lives only behind the drawer/Home card). Every profile save triggers a full loadProfile() which re-fetches profile + couple + partner (3 queries). Avatars go to a public, never-expiring URL.
- scale reason: Low traffic; the risks are consent-model and product-gap, not throughput.

## Ads  [risk: none]
- purpose: AdMob banner monetisation.
- files: E:/LDR/mobile/lib/core/ads/ad_config.dart, ad_service.dart, banner_ad_slot.dart; single mount point app_shell.dart:241 (Touch tab only); AdService.init() at main.dart:80
- tables: none
- transport: none
- how it works: AdConfig.adsEnabled is hardcoded false and AdConfig.useTestAds is hardcoded true; the three production unit IDs are the literal strings 'REPLACE_WITH_YOUR_BANNER_UNIT_ID' etc. BannerAdSlot._load() returns immediately when adsEnabled is false, so no ad is ever requested. AdService.init() still initialises the Google Mobile Ads SDK on every cold start.
- weaknesses: The module produces zero revenue and cannot without a code change. The SDK is still initialised and google_mobile_ads is still a dependency, which pulls the Android AD_ID permission into the manifest and therefore onto the Play Data Safety form for a feature that does nothing. Banner is placed only on the Touch tab.
- scale reason: Inert. Note for redesign: monetisation is currently a stub, not a revenue path.

## Daily prompt  [risk: medium]
- purpose: One shared question per day; both answers revealed once both have responded.
- files: E:/LDR/mobile/lib/features/daily_prompt/daily_prompt_screen.dart (route /app/prompt, drawer), daily_prompt_repository.dart
- tables: daily_prompts (couple_id, prompt_text, scheduled_date, unique(couple_id, scheduled_date)), prompt_responses (prompt_id, user_id, response_text, unique(prompt_id,user_id)) — both in schema.sql with explicit RLS.
- transport: none — pure fetch on open.
- how it works: ensureToday() takes the DEVICE's local calendar date, SELECTs a daily_prompts row for (couple_id, that date), and if absent INSERTs one whose text is promptPool[dayOfYear % 20]. Answers are upserted into prompt_responses.
- weaknesses: This breaks on exactly the users it is built for. Two partners in different timezones produce two DIFFERENT scheduled_date values for the same evening, so each creates and answers their OWN daily_prompts row and neither ever sees the other's answer — the reveal never happens. If both open it at the same moment in the same timezone, both INSERT and the loser hits the unique constraint through .single(), which throws an unhandled PostgrestException. Pool is 20 prompts on a 365-day modulus, so the same question recurs roughly every 20 days forever.
- scale reason: Correctness failure that scales with timezone diversity (i.e. with the target market), plus an insert race with no upsert/on-conflict handling.

## Reasons ('reasons I love you' jar)  [risk: medium]
- purpose: Shared list of reasons, one featured per day.
- files: E:/LDR/mobile/lib/features/reasons/reasons_screen.dart (route /app/reasons, drawer), reasons_repository.dart
- tables: love_reasons (couple_id, author, text, created_at) — NO DDL ANYWHERE IN E:/LDR/supabase. RLS unverifiable from source.
- transport: postgres_changes (all events) on love_reasons filtered by couple_id via ManagedSubscription; full list refetch on any change. No push.
- how it works: Plain insert/select/delete of plaintext rows, ordered created_at DESC with no limit. The 'featured' reason is _reasons[dayOfYear % _reasons.length] computed from the device date over the DESC-ordered list.
- weaknesses: Backend object missing from version control. The featured pick is computed over a list whose ordering shifts every time anyone adds a reason, so 'today's reason' changes mid-day; and because it uses the local device date, the two partners can see different featured reasons on the same day. The list query has no limit — a couple with a thousand reasons refetches all of them on every realtime event.
- scale reason: Unbounded SELECT re-run on every insert/delete, plus a table with no committed schema or index.

## Timeline / visits  [risk: low]
- purpose: Countdown to the next visit and a history of past visits.
- files: E:/LDR/mobile/lib/features/timeline/timeline_screen.dart (route /app/timeline, drawer), timeline_repository.dart
- tables: visits (schema.sql:41-50, couple-scoped RLS, indexed on (couple_id,is_upcoming,start_date)). visit_memories exists in schema.sql with full RLS but is NEVER referenced by any client code — a dead table.
- transport: none — fetch on didChangeDependencies.
- how it works: SELECT * from visits ordered by start_date; the screen computes the countdown from DateTime.now() locally and renders past/future sections.
- weaknesses: No realtime, so a visit added by one partner is invisible to the other until they reopen the screen. Countdown is device-clock based and uses no partner timezone. The photo-memories half of the feature (visit_memories) was schema'd and RLS'd but never built.
- scale reason: Small bounded reads, properly indexed.

## Together (shared presence room)  [risk: low]
- purpose: Two avatars in a shared space that lean together and emit hearts/kisses when either taps.
- files: E:/LDR/mobile/lib/features/together/together_screen.dart (route /app/together, drawer)
- tables: presence.avatar_emoji only (read via fetchMine/fetchPartner, written via PresenceService.setAvatarEmoji).
- transport: Broadcast channel `together:<coupleId>`, event 'moment'. Ephemeral.
- how it works: Each tap sends {action} on the broadcast channel and plays the animation locally; the receiver plays the same animation. Nothing is stored.
- weaknesses: Requires both partners on the screen simultaneously with a live socket; nothing arrives otherwise and there is no indication it was missed. Unauthorized broadcast channel keyed on couple_id (same exposure as the games). Avatar emoji is fetched once on init and never re-read, so a partner changing theirs is not reflected until reopen.
- scale reason: Low message volume, but shares the unauthorized-channel exposure.

## Watch Together  [risk: medium]
- purpose: Paste a YouTube link and keep play/pause/seek loosely synced on both phones.
- files: E:/LDR/mobile/lib/features/watch/watch_together_screen.dart (route /app/watch, drawer)
- tables: none — nothing is persisted, not even the current video.
- transport: Broadcast channel `watch:<coupleId>`, event 'watch', plus an unconditional 2500ms Timer.periodic that re-broadcasts {videoId, playing, positionMs} (watch_together_screen.dart:48).
- how it works: youtube_player_flutter drives playback locally; a 2.5s heartbeat plus a play/pause listener push state; the receiver seeks only when drift exceeds 2500ms and suppresses echo with a 600ms _applyingRemote flag.
- weaknesses: Position is compared as raw player positions with no clock/latency compensation, so the tolerated drift is up to ~2.5s by design and network latency is never subtracted. Both users touching controls produces an oscillation the 600ms guard only partially damps. Nothing survives leaving the screen — no 'resume where we were'. Unauthorized broadcast channel keyed on couple_id. YouTube ToS around synchronised third-party playback is not addressed anywhere.
- scale reason: 24 broadcast messages per user per minute while watching (48 per couple), continuous for the length of a film — the highest sustained broadcast rate in the app after Heartbeat.

## Heartbeat (PPG pulse sharing)  [risk: high]
- purpose: Measure the user's pulse with the camera+torch and let the partner feel each beat as a haptic.
- files: E:/LDR/mobile/lib/features/heartbeat/heartbeat_screen.dart (route /app/heartbeat, drawer), ppg_detector.dart
- tables: none — no BPM is ever stored.
- transport: Broadcast channel `heartbeat:<coupleId>`, event 'hb'. One message PER DETECTED BEAT (heartbeat_screen.dart:177) plus one per BPM update plus one on stop.
- how it works: CameraController at ResolutionPreset.low with the torch on, startImageStream, luma-plane mean sampled every 16th byte, fed to PpgDetector which emits onBeat/onBpm. Each callback fires a broadcast; the receiver triggers HapticFeedback.lightImpact() per beat.
- weaknesses: Requires both partners in the screen simultaneously on a live socket. Raw biometric data (heart rate) travels over an UNAUTHORIZED public broadcast channel keyed on couple_id — anyone who knows the id can read it. No consent gate on either side. Camera+torch at full duty cycle is a battery and thermal load; the lifecycle guard exists precisely because it previously kept the torch lit behind the disguise cover.
- scale reason: ~70-90 broadcast messages per user per minute — by far the highest realtime message rate in the app. 100 concurrent pairs ≈ 15,000 Realtime messages/minute for a feature with zero durable value, and Supabase bills broadcast messages.

## Time capsules + proximity unlock  [risk: medium]
- purpose: Sealed collection of notes/photos/voice that unlocks on a date, on physical proximity, or both.
- files: E:/LDR/mobile/lib/features/capsule/{capsule_list_screen,capsule_create_screen,capsule_detail_screen,capsule_fill_screen,capsule_repository,proximity_service}.dart (routes /app/capsule*)
- tables: capsules, capsule_items (capsules.sql, with a sealed-until-unlocked SELECT policy), storage bucket capsule-media (private, folder-scoped policies). RPCs capsule_seal_summary(uuid), unlock_capsule(uuid).
- transport: postgres_changes on `capsules` (in the realtime publication); proximity uses an EPHEMERAL broadcast channel with a 4s ping timer (proximity_service.dart:107). capsule_list_screen also runs a 30s poll timer.
- how it works: Items are un-SELECTable until capsules.unlocked_at is set. unlock_capsule() is SECURITY DEFINER and validates the date for modes 'date' and 'both'. Proximity is computed entirely client-side: each phone broadcasts its own coarse position on a realtime channel every 4s and both compute the Haversine distance locally; no coordinate is ever persisted.
- weaknesses: For unlock_mode='proximity' the RPC performs NO check at all (capsules.sql:87-92 only branches on 'date' and 'both') — any couple member can call unlock_capsule directly and open a proximity capsule from anywhere. The proximity broadcast channel is unauthorized like every other broadcast channel here, so live coarse coordinates are readable by anyone who knows the couple_id. Both phones must be in the screen at the same moment for a proximity unlock to ever trigger.
- scale reason: 4s position pings per user while the screen is open, a 30s list poll, and a server-side seal whose central promise (proximity) is enforced only in Dart.

## Fake News cover (disguise front screen)  [risk: medium]
- purpose: The 'News' app the launcher disguise shows; must look genuine.
- files: E:/LDR/mobile/lib/features/fake_news/fake_news_screen.dart, rss_service.dart; hosted by features/disguise/disguise_cover_host.dart
- tables: none — a static in-memory cache (RssService.cached / cachedAt).
- transport: none. Plain HTTPS GET.
- how it works: Sequentially fetches three public RSS feeds (feeds.bbci.co.uk, aljazeera.com, feeds.npr.org) with a spoofed 'Mozilla/5.0' User-Agent and a 6s timeout each, parses XML, sorts by pubDate, keeps 30 items in a static field that survives screen rebuilds.
- weaknesses: Three unpaid third-party endpoints fetched directly from every user's device with a spoofed UA — BBC/NPR/Al Jazeera will rate-limit or block by IP/UA at volume, and the cover screen then renders empty, which is exactly when the disguise fails. Fetches are sequential, so a slow feed adds up to 18s before content appears. No disk cache, no ETag, no stale-while-revalidate.
- scale reason: Direct client fan-out to third-party feeds that have no agreement with this app; needs a server-side cached feed proxy before thousands of devices poll them.

## App shell, navigation and screen-presence publishing  [risk: high]
- purpose: Bottom-nav container, app-wide Reach/call listeners, realtime reconnection, and publishing 'which screen am I on' to the partner.
- files: E:/LDR/mobile/lib/features/shell/app_shell.dart, app_drawer.dart, E:/LDR/mobile/lib/core/presence_route_observer.dart, core/screen_presence.dart, core/widgets/partner_here_badge.dart, core/realtime_resume.dart, core/realtime_service.dart
- tables: presence.current_screen (durable fallback)
- transport: Broadcast channel `screen_presence:<coupleId>` (events 'screen' and 'warm') for sub-second sync, backed by a presence-table write for durability. Plus the app-wide reach_events postgres_changes subscription.
- how it works: A NavigatorObserver reports every push/pop/replace, and AppShell calls publishActiveTab() on tab changes (tabs are setState, not routes). Each report broadcasts the screen name AND upserts presence.current_screen with isAppActivity:true. On every AppLifecycleState.resumed, AppShell calls realtime.disconnect() then realtime.connect() (app_shell.dart:70-80), and the resulting onOpen fans out through realtimeResumed so every ManagedSubscription tears its channel down (awaited removeChannel) and rebuilds it.
- weaknesses: Every navigation is a database write, and the app has 44 routes — browsing the drawer generates a presence UPSERT per screen. The forced full-socket disconnect/reconnect on every foreground means every mounted subscription in the app rejoins at once. Three modules (notably cycle_screen.dart:64-75) still use the old unsubscribe()+re-channel() pattern instead of ManagedSubscription and can leave duplicate-topic dead channels.
- scale reason: A per-navigation write amplification pattern plus a per-foreground socket storm. Thousands of users backgrounding/foregrounding produce synchronized reconnect + rejoin bursts against Supabase Realtime, which is exactly the load pattern that causes channel-join throttling.

## Push fan-in (reach-notify edge function)  [risk: fatal]
- purpose: Single edge function that turns reach, care, call and message inserts into FCM notifications.
- files: E:/LDR/supabase/functions/reach-notify/index.ts; triggers in fcm_push.sql (reach), 20260628_care_call_push.sql (care, call), message_push.sql (message); client side E:/LDR/mobile/lib/core/services/fcm_service.dart and core/services/reach_notifications.dart
- tables: profiles.fcm_token / fcm_token_updated_at; reads profiles to resolve the recipient (couple_id = X and id <> sender, limit 1)
- transport: FCM HTTP v1, data-only messages so the Android background isolate builds the notification wearing the current disguise.
- how it works: Four AFTER INSERT triggers each perform net.http_post to the same function with {kind, record}. The function mints a fresh RS256 service-account JWT and exchanges it at oauth2.googleapis.com for an access token ON EVERY INVOCATION, looks up the recipient's single fcm_token, resolves the sender name, and posts to FCM with ttl 30s (86400s for messages). Unregistered tokens are nulled out. Every failure path returns HTTP 200.
- weaknesses: No token caching: one Google OAuth round trip per notification. One fcm_token column per user means multi-device is impossible — a second install silently steals notifications from the first. pg_net is fire-and-forget and discards the response, so the only diagnostic is net._http_response (documented in message_push.sql). Returning 200 on every error means monitoring sees a healthy function while delivery is 100% failing. Every notification body is a generic disguise string with no content, so push conveys 'something happened' and nothing more.
- scale reason: Every single user-visible event in the app (every chat message, reach, nudge, call) becomes: trigger → pg_net HTTP → edge function cold start → OAuth token exchange → profiles lookup ×2 → FCM POST. At thousands of users this saturates pg_net's worker queue and Google's token endpoint quota; it needs batching, a cached token, and a proper worker/queue rather than per-row HTTP from Postgres.

## Schema management / backend reproducibility  [risk: fatal]
- purpose: How the Postgres schema and buckets are defined and deployed.
- files: E:/LDR/supabase/*.sql (43 loose files), E:/LDR/supabase/.temp/linked-project.json; no supabase/migrations/, no config.toml, no seed
- tables: All of them. Client-referenced tables with NO DDL in the repo: care_nudges, cycle_settings, cycle_events, love_reasons. Storage buckets with no DDL: couple_media, couple_intimate, chat-bg (only capsule-media is created, capsules.sql:110). SQL-defined tables no client ever touches: reach_pulses, visit_memories, mood_lamp, consent_state, couple_dissolutions, fantasy_jar_reveals.
- transport: n/a
- how it works: Ordered-by-header-comment .sql files applied by hand in the Supabase SQL editor (several files say so in their headers), plus out-of-band DDL applied via MCP. Later files patch earlier ones (hardening_2026_08.sql, hardening_couple_id_fix.sql, newuser_fixes.sql) rather than superseding them, so the true schema is the union of 43 files applied in an order recorded nowhere machine-readable.
- weaknesses: A fresh Supabase project cannot be rebuilt from this directory — four live tables and three buckets have no definition, so a staging environment silently loses Care, Cycle and Reasons and gets an unknown storage/RLS posture. The RLS protecting the app's most sensitive data (menstrual cycle history) is unverifiable from source. Dead client code calls a dropped function: SupabaseRepository.joinCouple invokes join_couple_by_code, which hardening_2026_08.sql:85 drops.
- scale reason: No reproducible environment means no staging, no reviewable RLS change, no rollback and no disaster recovery. Every other scaling fix in this list is gated on fixing this first.

