import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A partner's live presence row (online / typing / mood).
class Presence {
  Presence({
    required this.userId,
    bool isOnline = false,
    this.lastSeen,
    this.updatedAt,
    this.appLastActiveAt,
    this.isTyping = false,
    this.typingInChat = false,
    this.currentMood,
    this.moodColor,
    this.locationLabel,
    this.locationSharingMode = 'off',
    this.latitude,
    this.longitude,
    this.locationAccuracy,
    this.locationUpdatedAt,
    this.currentActivity,
    this.currentScreen,
    this.bodyPhotoPath,
    this.avatarEmoji,
    this.checkinPhotoUrl,
    this.checkinPhotoAt,
    this.chatLastRead,
  }) : isOnlineFlag = isOnline;

  /// This row with only its LIVENESS changed — everything else carried over.
  ///
  /// Deliberately not a general copyWith. The broadcast hint that calls this
  /// knows two things and nothing else; a full copyWith would invite a caller
  /// to blank the screen, mood or location from a payload that never carried
  /// them, a moment before the database says otherwise.
  Presence withLiveness({bool? isOnline, DateTime? appLastActiveAt}) => Presence(
        userId: userId,
        isOnline: isOnline ?? isOnlineFlag,
        lastSeen: lastSeen,
        updatedAt: updatedAt,
        appLastActiveAt: appLastActiveAt ?? this.appLastActiveAt,
        isTyping: isTyping,
        typingInChat: typingInChat,
        currentMood: currentMood,
        moodColor: moodColor,
        locationLabel: locationLabel,
        locationSharingMode: locationSharingMode,
        latitude: latitude,
        longitude: longitude,
        locationAccuracy: locationAccuracy,
        locationUpdatedAt: locationUpdatedAt,
        currentActivity: currentActivity,
        currentScreen: currentScreen,
        bodyPhotoPath: bodyPhotoPath,
        avatarEmoji: avatarEmoji,
        checkinPhotoUrl: checkinPhotoUrl,
        checkinPhotoAt: checkinPhotoAt,
        chatLastRead: chatLastRead,
      );

  factory Presence.fromJson(Map<String, dynamic> j) => Presence(
        userId: JsonUtils.parseString(j['user_id']),
        isOnline: JsonUtils.parseBool(j['is_online']),
        lastSeen: JsonUtils.parseDateOrNull(j['last_seen'])?.toLocal(),
        updatedAt: JsonUtils.parseDateOrNull(j['updated_at'])?.toLocal(),
        // Dedicated app-activity timestamp (GPS-isolated). Parsed UTC because
        // every reader compares it via DateTime.now().toUtc().difference(...).
        appLastActiveAt:
            JsonUtils.parseDateOrNull(j['app_last_active_at'])?.toUtc(),
        isTyping: JsonUtils.parseBool(j['is_typing']),
        typingInChat: JsonUtils.parseBool(j['typing_in_chat']),
        currentMood: JsonUtils.parseStringOrNull(j['current_mood']),
        moodColor: JsonUtils.parseStringOrNull(j['mood_color']),
        locationLabel: JsonUtils.parseStringOrNull(j['location_label']),
        locationSharingMode:
            JsonUtils.parseString(j['location_sharing_mode'], fallback: 'off'),
        latitude:
            j['latitude'] == null ? null : JsonUtils.parseDouble(j['latitude']),
        longitude: j['longitude'] == null
            ? null
            : JsonUtils.parseDouble(j['longitude']),
        locationAccuracy: j['location_accuracy'] == null
            ? null
            : JsonUtils.parseDouble(j['location_accuracy']),
        locationUpdatedAt:
            JsonUtils.parseDateOrNull(j['location_updated_at'])?.toLocal(),
        currentActivity: JsonUtils.parseStringOrNull(j['current_activity']),
        currentScreen: JsonUtils.parseStringOrNull(j['current_screen']),
        bodyPhotoPath: JsonUtils.parseStringOrNull(j['body_photo_path']),
        avatarEmoji: JsonUtils.parseStringOrNull(j['avatar_emoji']),
        checkinPhotoUrl: JsonUtils.parseStringOrNull(j['checkin_photo_url']),
        checkinPhotoAt:
            JsonUtils.parseDateOrNull(j['checkin_photo_at'])?.toLocal(),
        chatLastRead: JsonUtils.parseDateOrNull(j['chat_last_read'])?.toLocal(),
      );

  final String userId;

  /// The raw `is_online` DB flag — ADVISORY ONLY. A force-killed app never writes
  /// it false, so never read this directly for UI; use [isOnline] (freshness-gated).
  final bool isOnlineFlag;
  final DateTime? lastSeen;

  /// Generic "row last modified" — written by EVERY upsert, including GPS. Do
  /// NOT use this for presence/last-seen (GPS pollutes it). Use [appLastActiveAt].
  final DateTime? updatedAt;

  /// App-activity timestamp — written ONLY by genuine app usage, never by GPS.
  /// The single source of truth for online / last-seen / delivered.
  final DateTime? appLastActiveAt;
  final bool isTyping;
  final bool typingInChat;
  final String? currentMood;
  final String? moodColor;
  final String? locationLabel;
  final String locationSharingMode; // 'off' | 'city' | 'precise'
  final double? latitude;
  final double? longitude;
  final double? locationAccuracy;
  final DateTime? locationUpdatedAt;
  final String? currentActivity;
  final String? currentScreen;
  final String? bodyPhotoPath;
  final String? avatarEmoji;
  final String? checkinPhotoUrl;
  final DateTime? checkinPhotoAt;
  final DateTime? chatLastRead;

  /// GETTER 2 — is the partner looking at the chat RIGHT NOW?
  ///
  /// Ephemeral, and deliberately separate from [chatLastRead]. Deriving it from
  /// the read watermark meant the two had to be kept in sync by moving the
  /// watermark backwards, which un-read already-read messages.
  ///
  /// typing_in_chat is set on entering the chat and cleared on leaving, and is
  /// freshness-gated so a hard kill cannot leave it stuck on.
  bool get isActivelyInChat => typingInChat && isTrulyOnline;

  /// GETTER 1 — is the partner genuinely using the app right now?
  /// Source: app_last_active_at (NEVER updated_at / location), plus an explicit
  /// goodbye. Window 45s — the 30s foreground heartbeat keeps it fresh while
  /// active; on a kill it expires within 45s. Drives: Online subtitle, online
  /// dot, isActivelyInChat.
  bool get isTrulyOnline {
    final ts = appLastActiveAt;
    if (ts == null) return false;
    if (saidGoodbye) return false;
    // ServerClock, not DateTime.now(). app_last_active_at is stamped by the
    // SERVER now, so comparing it to this device's clock reintroduced exactly
    // the error the trigger removed — and directionally: a reader whose clock
    // runs slow sees their partner as permanently offline while looking online
    // to them.
    return ServerClock.now().difference(ts).inSeconds <= 45;
  }

  /// The partner's app said it was leaving, and nothing has happened since.
  ///
  /// Freshness alone can only DECAY, never switch. The heartbeat re-stamps
  /// every 30s against a 45s window, so at the moment the app backgrounds the
  /// stamp is 0-30s old and keeps testing fresh for another 15-45s: the avatar
  /// held "Online" for 45-75s after the phone was put down, then jumped to "1
  /// minute ago". main.dart has always written `is_online:false` on the way
  /// out; no reader had ever looked at it.
  ///
  /// One-way, and that is the whole design. A false flag may push the partner
  /// offline; a true one may never pull them online, because a force-kill
  /// leaves `is_online` true on the row forever and the 45s window is the only
  /// thing that ever catches that. Freshness stays the backstop for every exit
  /// with no goodbye — crash, force-stop, battery death, dead network.
  ///
  /// The ordering guard is ONE clock, not two. Both timestamps are written by
  /// the same BEFORE trigger on the same row: `updated_at` on every upsert,
  /// `app_last_active_at` only on an activity write. So a goodbye that loses a
  /// race with a later resume carries the older stamp of the two and is
  /// discarded here rather than blinking the partner offline. (`isBefore`
  /// compares absolute instants, so the local/UTC parse split does not matter.)
  bool get saidGoodbye {
    if (isOnlineFlag) return false;
    final bye = updatedAt;
    final active = appLastActiveAt;
    if (bye == null || active == null) return false;
    return !bye.isBefore(active);
  }

  /// HONEST online for every reader (Home, drawer, chat) — same as
  /// [isTrulyOnline] (app-activity freshness, never the raw is_online flag, never
  /// GPS-polluted updated_at).
  bool get isOnline => isTrulyOnline;

  /// Back-compat alias for [isTrulyOnline].
  bool get onlineNow => isTrulyOnline;

  /// GETTER 3 — human-readable last-seen string.
  /// Source: app_last_active_at (NEVER updated_at, NEVER location). Returns null
  /// when online (caller shows "Online").
  String? get lastSeenText {
    if (isTrulyOnline) return null;
    final ts = appLastActiveAt;
    if (ts == null) return 'Offline';
    final age = DateTime.now().toUtc().difference(ts);
    if (age.inSeconds < 60) return 'Just now';
    if (age.inMinutes < 60) return '${age.inMinutes}m ago';
    if (age.inHours < 24) return '${age.inHours}h ago';
    if (age.inDays < 7) return '${age.inDays}d ago';
    return 'A while ago';
  }

  bool get isSharingLive =>
      locationSharingMode == 'precise' && latitude != null && longitude != null;

  /// Sharing a place name but no coordinates — the considerate setting.
  ///
  /// location_service.dart implements 'city' properly: it geocodes to a
  /// "City, Country" label and deliberately stores NO latitude or longitude.
  /// Nothing read that. Every surface asked [isSharingLive], which is false
  /// for city mode, so anyone who picked the polite option was reported to
  /// their partner as "isn't sharing right now" — the coarse choice was
  /// indistinguishable from off, which is the one thing it must never be.
  bool get isSharingCity =>
      locationSharingMode == 'city' &&
      (locationLabel?.isNotEmpty ?? false);

  /// Sharing anything at all, at any granularity.
  bool get isSharingAnything => isSharingLive || isSharingCity;
}

/// Couple-scoped presence read/write. RLS lets you update only your own row and
/// read your partner's.
class PresenceService {
  PresenceService._();

  static SupabaseClient get _c => SupabaseService.client;

  /// [isAppActivity] true ⇒ also stamp `app_last_active_at` (the GPS-isolated
  /// presence clock). Location upserts pass false (the default) so GPS pings
  /// never pollute online / last-seen.
  static Future<void> _upsert(
    String coupleId,
    Map<String, dynamic> patch, {
    required String op,
    bool isAppActivity = false,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    // Sent as a marker only. A BEFORE trigger replaces both with now(), so the
    // value here is never trusted — what matters is WHETHER the column is
    // present, which is how the server knows this write counts as activity.
    final now = DateTime.now().toUtc();
    final marker = now.toIso8601String();
    final sw = Stopwatch()..start();
    try {
      // couple_id is ALWAYS written (never conditional) so that if a row
      // somehow holds a stale couple_id, the very next presence write — any
      // heartbeat, typing, mood, location ping — self-heals it. onConflict is
      // pinned to the user_id primary key so the upsert updates in place.
      final rows = await _c.from('presence').upsert({
        'user_id': uid,
        'couple_id': coupleId,
        'updated_at': marker,
        if (isAppActivity) 'app_last_active_at': marker,
        ...patch,
      }, onConflict: 'user_id',).select('updated_at,app_last_active_at');

      // The row comes back carrying the timestamp the SERVER just wrote, so
      // the 30s heartbeat doubles as a clock sync with no extra round trip.
      final row = rows.isEmpty ? null : rows.first;
      final serverTs = row?['updated_at'];
      final serverAt =
          serverTs is String ? DateTime.tryParse(serverTs)?.toUtc() : null;
      if (serverAt != null) ServerClock.observe(serverAt, sentAt: now);

      // app_last_active_at is stamped by the trigger off the SERVER's clock, so
      // the identical integer lands in the partner's copy of this row. It is
      // the only key that joins the writer's trace to the reader's without
      // reconciling two device clocks first.
      final activeTs = row?['app_last_active_at'];
      final activeAt =
          activeTs is String ? DateTime.tryParse(activeTs)?.toUtc() : null;
      Diag.record(DiagArea.presence, 'presence_write',
          corr: activeAt == null
              ? null
              : 'hb:${activeAt.millisecondsSinceEpoch}',
          fields: {
            'op': op,
            'is_app_activity': isAppActivity,
            'outcome': 'ok',
            'ms': sw.elapsedMilliseconds,
            'rows_returned': rows.length,
            'server_ts_ms': serverAt?.millisecondsSinceEpoch,
            'app_active_ts_ms': activeAt?.millisecondsSinceEpoch,
          },);
    } catch (e) {
      // presence is best-effort; never surface an error to the user — but a
      // silent write failure here means no online status and no partner
      // screen, which is worth a line in the log.
      debugPrint('[presence] upsert failed: $e');
      // WHICH failure it was has never been recorded anywhere, so an RLS denial
      // and a column that does not exist have both looked exactly like a
      // successful write from the outside.
      Diag.record(DiagArea.presence, 'presence_write', fields: {
        'op': op,
        'is_app_activity': isAppActivity,
        'outcome': 'err',
        'err_class': e.runtimeType.toString(),
        if (e is PostgrestException) 'pg_code': e.code,
        if (e is PostgrestException) 'err_msg_len': e.message.length,
        'ms': sw.elapsedMilliseconds,
      },);
    }
  }

  // ╔═══════════════════════════════════════════════════════════════════════╗
  // ║ APP ACTIVITY — these stamp app_last_active_at (drives online/last-seen) ║
  // ╚═══════════════════════════════════════════════════════════════════════╝

  /// Stamp app activity ONLY when coming online. Going offline (online:false on
  /// pause/detach) must NOT stamp app_last_active_at — otherwise the partner
  /// would read "Online" for the full 45s window after the app is backgrounded.
  ///
  /// `online:false` is the app's explicit goodbye and [Presence.saidGoodbye]
  /// now reads it, so this is the write that SWITCHES the partner's avatar off
  /// instead of letting it decay. It has exactly one caller — main.dart on
  /// paused/detached — and that must stay true: anything else writing false
  /// would blink a partner offline while they were sitting in the app.
  /// last_seen stays advisory; the honest clocks are app_last_active_at and
  /// updated_at, both server-stamped.
  /// Whether a PERSON is actually looking at the real app right now.
  ///
  /// Set from `MilesApp.showRealApp`, which only goes true after the cover, the
  /// biometric gate and the splash. Everything that claims presence is gated on
  /// it, here rather than at each call site, because there are five callers and
  /// the next one added will not remember this rule.
  ///
  /// What it prevents: a Reach push resumes the recipient's app, resume starts
  /// the heartbeat, and the first beat stamps is_online, app_last_active_at and
  /// last_seen — so the sender is shown a partner who is awake and reading,
  /// while she is asleep and has touched nothing. A presence system that
  /// reports the PROCESS rather than the PERSON does not just show a wrong dot;
  /// it invents evidence of being ignored.
  static bool humanPresent = false;

  /// The partner's online/offline as it arrives over the BROADCAST rail, ahead
  /// of the database.
  ///
  /// Presence used to be visible only after a Postgres write and a
  /// postgres_changes hop — ~750ms to 1.2s to notice somebody left, which reads
  /// as the avatar lingering. The socket already carries typing and read
  /// receipts in ~100ms on `screen_presence:<coupleId>`; this puts leaving and
  /// arriving on the same rail. The database write is untouched and remains the
  /// durable record for anyone who was not connected when it happened.
  ///
  /// Carries the sender's clock so a REORDERED broadcast cannot win: broadcasts
  /// are best-effort and unordered, and a stale "online" arriving after a fresh
  /// "offline" would resurrect an avatar that had already gone.
  static final ValueNotifier<({bool online, DateTime at})?> liveHint =
      ValueNotifier(null);

  /// Applied from the broadcast handler. Older-or-equal hints are dropped.
  static void applyLiveHint({required bool online, required DateTime at}) {
    final prev = liveHint.value;
    if (prev != null && !at.isAfter(prev.at)) return;
    liveHint.value = (online: online, at: at);
  }

  static Future<void> setOnline(String coupleId, {required bool online}) {
    // Claiming presence requires a person. Going OFFLINE is always allowed —
    // it is the honest direction, and a goodbye written as the app dies must
    // never be gated on a flag the teardown may already have cleared.
    if (online && !humanPresent) {
      debugPrint('[presence] online claim refused: nobody is looking');
      return Future<void>.value();
    }
    return _upsert(
      coupleId,
      {
        'is_online': online,
        // last_seen moves ONLY with a real online claim. It rode along on every
        // write, so a push-woken process that wrote anything at all pushed
        // "last seen" to now — the timestamp the partner reads as "she was just
        // here".
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      },
      op: 'set_online',
      isAppActivity: online,
    );
  }

  static Future<void> setTyping(String coupleId, {required bool typing}) =>
      _upsert(coupleId, {'is_typing': typing},
          op: 'set_typing', isAppActivity: true,);

  static Future<void> setTypingInChat(String coupleId,
          {required bool inChat,}) =>
      _upsert(coupleId, {'typing_in_chat': inChat},
          op: 'set_typing_in_chat', isAppActivity: true,);

  /// Marks the chat read "now" — on entering and on leaving, the two moments
  /// the watermark is defined. The live read position rides the chat's own
  /// broadcast channel and `chat_receipts`; this is the durable trace.
  static Future<void> setChatLastRead(String coupleId) => _upsert(
        coupleId,
        {'chat_last_read': DateTime.now().toUtc().toIso8601String()},
        op: 'set_chat_last_read',
        isAppActivity: true,
      );

  /// Clears the "in chat" + typing state on exit (app backgrounded / killed).
  ///
  /// It used to also rewrite chat_last_read FIVE MINUTES INTO THE PAST, to force
  /// isActivelyInChat false. That destroyed the one guarantee a read receipt
  /// has: chat_last_read is a WATERMARK, and a watermark that moves backwards
  /// un-reads messages that were already read. The reported symptom was exactly
  /// that — every green tick in the conversation turning black the moment the
  /// partner closed the chat.
  ///
  /// typing_in_chat already carries "is she in the chat right now". The two
  /// facts are separate and are stored separately now.
  ///
  /// Intentionally NOT isAppActivity: this fires on leave/background, and
  /// stamping app_last_active_at here would keep the partner reading "Online"
  /// for the full 45s window. Letting it expire naturally (last heartbeat ≤30s
  /// ago) shows "Just now" and flips to offline within the window — honest.
  static Future<void> clearChatPresence(String coupleId) => _upsert(
        coupleId,
        {
          'typing_in_chat': false,
          'is_typing': false,
        },
        op: 'clear_chat_presence',
      );

  static Future<void> setMood(String coupleId, String mood, String color) =>
      _upsert(
        coupleId,
        {
          'current_mood': mood,
          'mood_color': color,
          'mood_updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        op: 'set_mood',
        isAppActivity: true,
      );

  /// Which feature/section the user is currently in (so the partner can see).
  static Future<void> setScreen(String coupleId, String? screen) =>
      _upsert(coupleId, {'current_screen': screen},
          op: 'set_screen', isAppActivity: true,);

  /// The user's full-body photo for the Touch feature (private bucket path).
  static Future<void> setBodyPhoto(String coupleId, String path) =>
      _upsert(coupleId, {'body_photo_path': path},
          op: 'set_body_photo', isAppActivity: true,);

  // ╔═══════════════════════════════════════════════════════════════════════╗
  // ║ LOCATION ONLY — never stamps app_last_active_at. GPS runs while the     ║
  // ║ user is asleep; it must never touch the app-activity / last-seen clock.║
  // ╚═══════════════════════════════════════════════════════════════════════╝

  static Future<void> setSharingMode(String coupleId, String mode) =>
      _upsert(coupleId, {'location_sharing_mode': mode},
          op: 'set_sharing_mode',);

  static Future<void> setLocation(
    String coupleId, {
    required String mode,
    double? lat,
    double? lon,
    double? accuracy,
    String? label,
  }) =>
      _upsert(coupleId, {
        'location_sharing_mode': mode,
        'latitude': lat,
        'longitude': lon,
        'location_accuracy': accuracy,
        'location_label': label,
        // Freshness for the partner's "Xs ago". GPS-only: _upsert never stamps
        // app_last_active_at (isAppActivity:false), so location updates can't
        // make anyone read as falsely "online" / "active".
        'location_updated_at': DateTime.now().toUtc().toIso8601String(),
      }, op: 'set_location',);

  /// A single live-location tick (precise mode): coords + accuracy + freshness.
  static Future<void> setLiveLocation(
    String coupleId, {
    required double lat,
    required double lon,
    double? accuracy,
    String? label,
  }) =>
      _upsert(coupleId, {
        'location_sharing_mode': 'precise',
        'latitude': lat,
        'longitude': lon,
        'location_accuracy': accuracy,
        'location_updated_at': DateTime.now().toUtc().toIso8601String(),
        // Only overwrite the label when we re-geocoded (keeps the dashboard
        // text in sync with the live map without geocoding every tick).
        if (label != null) 'location_label': label,
      }, op: 'set_live_location',);

  /// Clears coords when live sharing stops (so the partner sees "paused", not a
  /// stale pin presented as live).
  static Future<void> clearLiveLocation(String coupleId) => _upsert(coupleId, {
        'location_sharing_mode': 'off',
        'latitude': null,
        'longitude': null,
        'location_accuracy': null,
      }, op: 'clear_live_location',);

  /// App activity (the user actively shared a snap) — stamps app_last_active_at.
  static Future<void> setCheckinPhoto(String coupleId, String url) => _upsert(
        coupleId,
        {
          'checkin_photo_url': url,
          'checkin_photo_at': DateTime.now().toUtc().toIso8601String(),
        },
        op: 'set_checkin_photo',
        isAppActivity: true,
      );

  /// The partner's presence row.
  ///
  /// Takes the freshest matching row rather than insisting there is exactly
  /// one. maybeSingle() ERRORS when more than one row comes back, and a couple
  /// can end up with a stray third row — an earlier member, a re-pair, a
  /// half-finished leave. That threw inside _bind, which had no catch, so the
  /// realtime subscribe below it never ran either: that user saw no presence at
  /// all while their partner saw everything, because the failure depends on
  /// which rows happen to exist on each side.
  static Future<Presence?> fetchPartner(String coupleId,
      {String src = 'other',}) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;
    final sw = Stopwatch()..start();
    try {
      final rows = await _c
          .from('presence')
          .select()
          .eq('couple_id', coupleId)
          .neq('user_id', uid)
          .order('updated_at', ascending: false)
          // Three so the count is real. updated_at is bumped by every upsert
          // including a GPS ping, so a stray third row for the couple can sort
          // above the partner's — with a limit of 1 that arrives as a perfectly
          // ordinary answer. rows.first is still what is used; only the count
          // is new.
          .limit(3);
      final p = rows.isEmpty ? null : Presence.fromJson(rows.first);
      final active = p?.appLastActiveAt;
      Diag.record(DiagArea.presence, 'presence_partner_read',
          corr: active == null
              ? null
              : 'hb:${active.millisecondsSinceEpoch}',
          fields: {
            'src': src,
            'outcome': rows.isEmpty ? 'empty' : 'ok',
            'ms': sw.elapsedMilliseconds,
            'rows_len': rows.length,
            // More than one candidate row IS the stray-row failure: the newest
            // is not necessarily the partner's once GPS has bumped updated_at.
            'distinct_users': rows.map((r) => r['user_id']).toSet().length,
            'has_app_active': active != null,
            if (active != null)
              'app_active_age_ms':
                  ServerClock.now().difference(active).inMilliseconds,
            'truly_online': p?.isTrulyOnline,
            'is_online_flag': p?.isOnlineFlag,
            // Distinguishes the two ways of being offline: an explicit goodbye
            // (they backgrounded) from a decayed window (they vanished).
            'said_goodbye': p?.saidGoodbye,
            'has_screen': p?.currentScreen != null,
            // False means freshness was measured against the raw device clock,
            // which is indistinguishable from a partner who is simply offline.
            'clock_known': ServerClock.isKnown,
          },);
      return p;
    } catch (e) {
      Diag.record(DiagArea.presence, 'presence_partner_read', fields: {
        'src': src,
        'outcome': 'err',
        'err_class': e.runtimeType.toString(),
        'ms': sw.elapsedMilliseconds,
      },);
      rethrow;
    }
  }

  static Future<Presence?> fetchMine(String coupleId) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;
    final res =
        await _c.from('presence').select().eq('user_id', uid).maybeSingle();
    return res == null ? null : Presence.fromJson(res);
  }
}

/// Live partner presence — refetches on any presence change for the couple.
class PartnerPresenceNotifier extends StateNotifier<Presence?> {
  PartnerPresenceNotifier(this.ref) : super(null) {
    // The couple resolves ASYNCHRONOUSLY — it's null until the profile load
    // finishes. React to it instead of reading once: bind the moment a non-null
    // couple appears, and rebind if it changes. Without this, a notifier created
    // during the null-couple window (cold start, after a token refresh, or the
    // always-mounted debug overlay) would early-return forever — null state and
    // zero realtime events. fireImmediately covers the already-loaded case.
    ref.listen(currentCoupleProvider, (prev, next) {
      final id = next?.id;
      if (id == null) {
        _coupleId = null;
        // Nothing else happens here: the channel stays joined against an id
        // that is now null. From the outside that is identical to a partner who
        // never writes, so it gets its own phase.
        Diag.record(DiagArea.presence, 'presence_bind', fields: {
          'phase': 'couple_null',
          'has_couple': false,
          'chan_live': _sub?.channel != null,
        },);
      } else if (id != _coupleId) {
        _bind(id);
      }
    }, fireImmediately: true,);
    realtimeResumed.addListener(_refetchOnResume); // read the gap on reconnect
    PresenceService.liveHint.addListener(_onLiveHint);
  }

  /// The socket said the partner arrived or left. Show it now.
  ///
  /// Only the liveness fields move — a hint carries no screen, mood or
  /// location, and inventing those from it would blank real values a moment
  /// before the database confirms them. The postgres_changes event that follows
  /// ~500ms later carries the whole row and reconciles.
  void _onLiveHint() {
    final hint = PresenceService.liveHint.value;
    final cur = state;
    if (hint == null || cur == null) return;
    _apply(cur.withLiveness(
      isOnline: hint.online,
      // isTrulyOnline reads app_last_active_at against the 45s window, so an
      // arrival has to move that clock or the avatar stays dark until the
      // database catches up — which is the latency this exists to remove.
      appLastActiveAt: hint.online ? hint.at : null,
    ),);
  }

  final Ref ref;
  ManagedSubscription? _sub;
  String? _coupleId;
  Timer? _expiry;
  Timer? _refetchDebounce;

  /// Binds to a (now-resolved) couple: fetch the partner row and subscribe to
  /// the presence channel. Called reactively when the couple becomes available
  /// — never with a null id.
  Future<void> _bind(String coupleId) async {
    final isFirst = _coupleId == null;
    _coupleId = coupleId;
    Diag.record(DiagArea.presence, 'presence_bind', fields: {
      'phase': 'start',
      'has_couple': true,
      'is_first': isFirst,
    },);
    var fetchOk = true;
    try {
      final p = await PresenceService.fetchPartner(coupleId, src: 'bind');
      if (mounted) _apply(p);
    } catch (e) {
      // The initial read is a convenience; realtime is the actual mechanism.
      // Letting a failed fetch skip _subscribe() is what turned one bad row
      // into "she can never see where I am", permanently, on one side only.
      fetchOk = false;
      debugPrint('[presence] initial partner fetch failed: $e');
    }
    _subscribe();
    Diag.record(DiagArea.presence, 'presence_bind', fields: {
      'phase': 'done',
      'has_couple': true,
      'is_first': isFirst,
      'fetch_ok': fetchOk,
    },);
  }

  /// Publish [p] and re-arm the liveness timer for it.
  void _apply(Presence? p) {
    state = p;
    _expiry?.cancel();
    final ts = p?.appLastActiveAt;
    if (ts == null) return;
    final left = const Duration(seconds: 45) - ServerClock.now().difference(ts);
    if (left <= Duration.zero) return;
    // A 15s REST poll used to run here for the life of every session — four
    // reads a minute, per online user, to notice a change that can only happen
    // at one knowable instant. isTrulyOnline is a pure function of
    // app_last_active_at and the 45s window, so the single moment liveness can
    // turn over without an event is when that window closes. A partner who
    // keeps beating pushes this timer forward and costs no read at all; one who
    // was force-killed costs exactly one, which also re-reads anything the
    // socket missed.
    _expiry = Timer(left + const Duration(seconds: 1), () async {
      final id = _coupleId;
      if (id == null) return;
      final fresh = await PresenceService.fetchPartner(id, src: 'expiry');
      if (mounted) _apply(fresh);
    });
  }

  void _subscribe() {
    final id = _coupleId;
    if (id == null) return;
    _sub?.dispose();
    // ManagedSubscription, so a socket reconnect rebuilds the channel cleanly
    // (awaited removeChannel before re-creating, never a duplicate-topic
    // 'presence:<id>' left joined-but-dead) and a refused join is retried. That
    // bug stopped the partner's presence updates (is_online=false on close)
    // from ever arriving, leaving a stale "online"/"delivered".
    _sub = ManagedSubscription.start(
      () => RealtimeService.coupleTable(
        channelName: 'presence:$id',
        table: 'presence',
        coupleId: id,
        onChange: (payload) {
          // Carries the same hb: key the writer recorded, which is the whole
          // point: a presence_write with no arrival here is a delivery failure,
          // while an arrival with no write belongs to somebody else's row.
          final activeTs = payload.newRecord['app_last_active_at'];
          final activeAt = activeTs is String
              ? DateTime.tryParse(activeTs)?.toUtc()
              : null;
          Diag.record(DiagArea.presence, 'presence_realtime_event',
              corr: activeAt == null
                  ? null
                  : 'hb:${activeAt.millisecondsSinceEpoch}',
              fields: {
                'event': payload.eventType.name,
                'is_self': payload.newRecord['user_id'] ==
                    SupabaseService.currentUserId,
                'has_app_active': activeAt != null,
              },);
          // APPLY WHAT THE EVENT ALREADY CARRIES, IMMEDIATELY.
          //
          // The row is in the payload. This used to throw it away and schedule
          // a debounced SELECT, so every presence change — going offline,
          // coming back, entering the chat — cost 800ms of timer plus a network
          // round trip before anything moved on screen. Both directions felt
          // laggy for the same reason, and no amount of speeding up the WRITER
          // could fix it, because the delay was entirely on the reader.
          //
          // Guarded on user_id: this channel carries BOTH rows in the couple,
          // and applying our own row as the partner's would show us our own
          // presence — which is why the refetch below asks for the partner by
          // id rather than trusting the event.
          final rowUser = payload.newRecord['user_id'];
          final me = SupabaseService.currentUserId;
          if (rowUser is String && rowUser.isNotEmpty && rowUser != me) {
            try {
              final live = Presence.fromJson(
                Map<String, dynamic>.from(payload.newRecord),
              );
              if (mounted) _apply(live);
            } catch (e) {
              // A partial payload is not a reason to drop the update — the
              // reconcile below still runs and is authoritative.
              debugPrint('[presence] realtime row unparsable: $e');
            }
          }

          // Reconcile. A single move can produce several writes in a row —
          // leaving the chat clears typing and stamps the watermark, arriving
          // somewhere sets the screen — and this collapses the burst into one
          // SELECT. It is now a CORRECTION rather than the thing the UI waits
          // on, so the delay costs nothing the user can see.
          _refetchDebounce?.cancel();
          _refetchDebounce =
              Timer(const Duration(milliseconds: 800), () async {
            final p = await PresenceService.fetchPartner(id, src: 'realtime');
            if (mounted) _apply(p);
          });
        },
      ),
    );
  }

  /// Pull current presence after a socket reconnect so we don't sit on a stale
  /// value. The channel itself is rebuilt by [ManagedSubscription].
  Future<void> _refetchOnResume() async {
    final id = _coupleId;
    if (id == null) return;
    final p = await PresenceService.fetchPartner(id, src: 'subscribe');
    if (mounted) _apply(p);
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _refetchDebounce?.cancel();
    realtimeResumed.removeListener(_refetchOnResume);
    _sub?.dispose();
    super.dispose();
  }
}

final partnerPresenceProvider =
    StateNotifierProvider.autoDispose<PartnerPresenceNotifier, Presence?>(
  PartnerPresenceNotifier.new,
);
