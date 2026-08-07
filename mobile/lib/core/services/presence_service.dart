import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/realtime_service.dart';
import 'package:miles/core/supabase_service.dart';
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

  /// GETTER 2 — is the partner actively reading the chat RIGHT NOW?
  /// Source: chat_last_read (written every 5s while the chat is open). Window
  /// 20s (> the 5s write cadence, tolerates a missed cycle without flicker).
  /// Drives: "is here" avatar + seen tick.
  bool get isActivelyInChat {
    if (chatLastRead == null) return false;
    final age = DateTime.now().toUtc().difference(chatLastRead!.toUtc());
    return age.inSeconds <= 20;
  }

  /// GETTER 1 — is the partner genuinely using the app right now?
  /// Source: app_last_active_at (NEVER updated_at / location). Window 45s — the
  /// 30s foreground heartbeat keeps it fresh while active; on a kill it expires
  /// within 45s. Drives: Online subtitle, delivered tick, online dot.
  bool get isTrulyOnline {
    final ts = appLastActiveAt;
    if (ts == null) return false;
    return DateTime.now().toUtc().difference(ts).inSeconds <= 45;
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
    bool isAppActivity = false,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      // couple_id is ALWAYS written (never conditional) so that if a row
      // somehow holds a stale couple_id, the very next presence write — any
      // heartbeat, typing, mood, location ping — self-heals it. onConflict is
      // pinned to the user_id primary key so the upsert updates in place.
      await _c.from('presence').upsert({
        'user_id': uid,
        'couple_id': coupleId,
        'updated_at': now,
        if (isAppActivity) 'app_last_active_at': now,
        ...patch,
      }, onConflict: 'user_id');
    } catch (_) {
      // presence is best-effort; never surface an error to the user
    }
  }

  // ╔═══════════════════════════════════════════════════════════════════════╗
  // ║ APP ACTIVITY — these stamp app_last_active_at (drives online/last-seen) ║
  // ╚═══════════════════════════════════════════════════════════════════════╝

  /// Stamp app activity ONLY when coming online. Going offline (online:false on
  /// pause/detach) must NOT stamp app_last_active_at — otherwise the partner
  /// would read "Online" for the full 45s window after the app is backgrounded.
  /// last_seen/is_online stay advisory; the honest clock is app_last_active_at.
  static Future<void> setOnline(String coupleId, {required bool online}) =>
      _upsert(
        coupleId,
        {
          'is_online': online,
          'last_seen': DateTime.now().toUtc().toIso8601String(),
        },
        isAppActivity: online,
      );

  static Future<void> setTyping(String coupleId, {required bool typing}) =>
      _upsert(coupleId, {'is_typing': typing}, isAppActivity: true);

  static Future<void> setTypingInChat(String coupleId,
          {required bool inChat}) =>
      _upsert(coupleId, {'typing_in_chat': inChat}, isAppActivity: true);

  /// Marks the chat read "now" — refreshed periodically while the chat is open.
  /// Drives the partner's read-receipts (seen) and the "in chat" avatar.
  static Future<void> setChatLastRead(String coupleId) => _upsert(
        coupleId,
        {'chat_last_read': DateTime.now().toUtc().toIso8601String()},
        isAppActivity: true,
      );

  /// Clears the "in chat" + typing state on exit (app backgrounded / killed).
  ///
  /// Writes a past chat_last_read so [Presence.isActivelyInChat] returns false
  /// immediately on the partner's next freshness check — killing the phantom
  /// "is here" avatar and any premature "seen" tick within the 20s window.
  /// Also clears typing flags so a half-finished typing indicator doesn't
  /// linger after the partner has left.
  ///
  /// Intentionally NOT isAppActivity: this fires on leave/background, and
  /// stamping app_last_active_at here would keep the partner reading "Online"
  /// for the full 45s window. Letting it expire naturally (last heartbeat ≤30s
  /// ago) shows "Just now" and flips to offline within the window — honest.
  static Future<void> clearChatPresence(String coupleId) => _upsert(coupleId, {
        'typing_in_chat': false,
        'is_typing': false,
        'chat_last_read': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 5))
            .toIso8601String(),
      });

  static Future<void> setMood(String coupleId, String mood, String color) =>
      _upsert(
        coupleId,
        {
          'current_mood': mood,
          'mood_color': color,
          'mood_updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        isAppActivity: true,
      );

  /// Which feature/section the user is currently in (so the partner can see).
  static Future<void> setScreen(String coupleId, String? screen) =>
      _upsert(coupleId, {'current_screen': screen}, isAppActivity: true);

  /// The user's full-body photo for the Touch feature (private bucket path).
  static Future<void> setBodyPhoto(String coupleId, String path) =>
      _upsert(coupleId, {'body_photo_path': path}, isAppActivity: true);

  /// The user's chosen avatar (emoji) for the "Together" space.
  static Future<void> setAvatarEmoji(String coupleId, String emoji) =>
      _upsert(coupleId, {'avatar_emoji': emoji}, isAppActivity: true);

  // ╔═══════════════════════════════════════════════════════════════════════╗
  // ║ LOCATION ONLY — never stamps app_last_active_at. GPS runs while the     ║
  // ║ user is asleep; it must never touch the app-activity / last-seen clock.║
  // ╚═══════════════════════════════════════════════════════════════════════╝

  static Future<void> setSharingMode(String coupleId, String mode) =>
      _upsert(coupleId, {'location_sharing_mode': mode});

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
      });

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
      });

  /// Clears coords when live sharing stops (so the partner sees "paused", not a
  /// stale pin presented as live).
  static Future<void> clearLiveLocation(String coupleId) => _upsert(coupleId, {
        'location_sharing_mode': 'off',
        'latitude': null,
        'longitude': null,
        'location_accuracy': null,
      });

  /// App activity (the user actively shared a snap) — stamps app_last_active_at.
  static Future<void> setCheckinPhoto(String coupleId, String url) => _upsert(
        coupleId,
        {
          'checkin_photo_url': url,
          'checkin_photo_at': DateTime.now().toUtc().toIso8601String(),
        },
        isAppActivity: true,
      );

  static Future<Presence?> fetchPartner(String coupleId) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;
    final res = await _c
        .from('presence')
        .select()
        .eq('couple_id', coupleId)
        .neq('user_id', uid)
        .maybeSingle();
    return res == null ? null : Presence.fromJson(res);
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
      } else if (id != _coupleId) {
        _bind(id);
      }
    }, fireImmediately: true);
    realtimeResumed.addListener(_subscribe); // rejoin + refetch on reconnect
  }

  final Ref ref;
  RealtimeChannel? _channel;
  String? _coupleId;
  bool _subscribing = false;
  Timer? _poll;
  Timer? _refetchDebounce;

  /// Binds to a (now-resolved) couple: fetch the partner row, subscribe to the
  /// presence channel, and start the liveness poll. Called reactively when the
  /// couple becomes available — never with a null id.
  Future<void> _bind(String coupleId) async {
    _coupleId = coupleId;
    final p = await PresenceService.fetchPartner(coupleId);
    if (mounted) state = p;
    await _subscribe();
    // Re-evaluate liveness even when no presence event fires (e.g. a hard-killed
    // partner writes nothing): refetch a fresh row so the freshness-gated getters
    // tick over and the UI drops to "offline" within the window. One shared poll
    // (autoDispose stops it when no screen is watching).
    _poll ??= Timer.periodic(const Duration(seconds: 15), (_) async {
      final id = _coupleId;
      if (id == null) return;
      final fresh = await PresenceService.fetchPartner(id);
      if (mounted) state = fresh;
    });
  }

  Future<void> _subscribe() async {
    final id = _coupleId;
    if (id == null || _subscribing) return;
    _subscribing = true;
    try {
      // Fully REMOVE the old channel (awaited) before re-creating, so we never
      // leave a duplicate-topic 'presence:<id>' channel joined-but-dead — that
      // bug stopped the partner's presence updates (is_online=false on close)
      // from ever arriving, leaving a stale "online"/"delivered".
      final old = _channel;
      _channel = null;
      if (old != null) {
        try {
          await SupabaseService.client.removeChannel(old);
        } catch (_) {}
      }
      _channel = RealtimeService.coupleTable(
        channelName: 'presence:$id',
        table: 'presence',
        coupleId: id,
        onChange: (_) {
          // The partner's client re-stamps presence every ~5s while their chat
          // is open, and every one of those writes used to trigger a full
          // SELECT here. Only the newest value matters, so coalesce bursts —
          // still authoritative, just not once per keystroke-era write.
          _refetchDebounce?.cancel();
          _refetchDebounce =
              Timer(const Duration(milliseconds: 800), () async {
            final p = await PresenceService.fetchPartner(id);
            if (mounted) state = p;
          });
        },
      );
      // Pull current presence on (re)connect so we don't sit on a stale value.
      final p = await PresenceService.fetchPartner(id);
      if (mounted) state = p;
    } finally {
      _subscribing = false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _refetchDebounce?.cancel();
    realtimeResumed.removeListener(_subscribe);
    final c = _channel;
    if (c != null) SupabaseService.client.removeChannel(c);
    super.dispose();
  }
}

final partnerPresenceProvider =
    StateNotifierProvider.autoDispose<PartnerPresenceNotifier, Presence?>(
  (ref) => PartnerPresenceNotifier(ref),
);
