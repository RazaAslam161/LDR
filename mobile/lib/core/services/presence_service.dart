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
  final DateTime? updatedAt;
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

  /// They're actively viewing the chat if they read within the last ~18s
  /// (the chat screen refreshes this every few seconds while open).
  bool get isInChatNow {
    final r = chatLastRead;
    return r != null && DateTime.now().difference(r).inSeconds < 18;
  }

  /// Liveness TTL: the presence row was written recently. A force-killed app
  /// runs no code and never writes is_online=false, so without this it would read
  /// online forever. The app heartbeats every ~20s while foregrounded (every ~5s
  /// in chat), so a 45s window tolerates a couple of missed writes. MUST stay
  /// greater than the heartbeat interval.
  bool get isFresh {
    final u = updatedAt;
    return u != null && DateTime.now().difference(u).inSeconds < 45;
  }

  /// HONEST online: the advisory flag AND a fresh heartbeat. This is the single
  /// source of truth every reader (Home, chat ticks, drawer) must use — never
  /// [isOnlineFlag] directly.
  bool get isOnline => isOnlineFlag && isFresh;

  /// Back-compat alias for [isOnline] (both are freshness-gated).
  bool get onlineNow => isOnline;

  bool get isSharingLive =>
      locationSharingMode == 'precise' && latitude != null && longitude != null;
}

/// Couple-scoped presence read/write. RLS lets you update only your own row and
/// read your partner's.
class PresenceService {
  PresenceService._();

  static SupabaseClient get _c => SupabaseService.client;

  static Future<void> _upsert(
      String coupleId, Map<String, dynamic> patch) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    try {
      await _c.from('presence').upsert({
        'user_id': uid,
        'couple_id': coupleId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        ...patch,
      });
    } catch (_) {
      // presence is best-effort; never surface an error to the user
    }
  }

  static Future<void> setOnline(String coupleId, {required bool online}) =>
      _upsert(coupleId, {
        'is_online': online,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      });

  static Future<void> setTyping(String coupleId, {required bool typing}) =>
      _upsert(coupleId, {'is_typing': typing});

  static Future<void> setTypingInChat(String coupleId,
          {required bool inChat}) =>
      _upsert(coupleId, {'typing_in_chat': inChat});

  /// Marks the chat read "now" — refreshed periodically while the chat is open.
  /// Drives the partner's read-receipts (seen) and the "in chat" avatar.
  static Future<void> setChatLastRead(String coupleId) => _upsert(coupleId, {
        'chat_last_read': DateTime.now().toUtc().toIso8601String(),
      });

  static Future<void> setMood(String coupleId, String mood, String color) =>
      _upsert(coupleId, {
        'current_mood': mood,
        'mood_color': color,
        'mood_updated_at': DateTime.now().toUtc().toIso8601String(),
      });

  /// Which feature/section the user is currently in (so the partner can see).
  static Future<void> setScreen(String coupleId, String? screen) =>
      _upsert(coupleId, {'current_screen': screen});

  /// The user's full-body photo for the Touch feature (private bucket path).
  static Future<void> setBodyPhoto(String coupleId, String path) =>
      _upsert(coupleId, {'body_photo_path': path});

  /// The user's chosen avatar (emoji) for the "Together" space.
  static Future<void> setAvatarEmoji(String coupleId, String emoji) =>
      _upsert(coupleId, {'avatar_emoji': emoji});

  static Future<void> setSharingMode(String coupleId, String mode) =>
      _upsert(coupleId, {'location_sharing_mode': mode});

  static Future<void> setLocation(
    String coupleId, {
    required String mode,
    double? lat,
    double? lon,
    String? label,
  }) =>
      _upsert(coupleId, {
        'location_sharing_mode': mode,
        'latitude': lat,
        'longitude': lon,
        'location_label': label,
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

  static Future<void> setCheckinPhoto(String coupleId, String url) =>
      _upsert(coupleId, {
        'checkin_photo_url': url,
        'checkin_photo_at': DateTime.now().toUtc().toIso8601String(),
      });

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
    _init();
    realtimeResumed.addListener(_subscribe); // rejoin + refetch on reconnect
  }

  final Ref ref;
  RealtimeChannel? _channel;
  String? _coupleId;
  bool _subscribing = false;
  Timer? _poll;

  Future<void> _init() async {
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    _coupleId = couple.id;
    state = await PresenceService.fetchPartner(couple.id);
    _subscribe();
    // Re-evaluate liveness even when no presence event fires (e.g. a hard-killed
    // partner writes nothing): refetch a fresh row so the freshness-gated getters
    // tick over and the UI drops to "offline" within the window. One shared poll
    // (autoDispose stops it when no screen is watching).
    _poll ??= Timer.periodic(const Duration(seconds: 15), (_) async {
      final id = _coupleId;
      if (id == null) return;
      final p = await PresenceService.fetchPartner(id);
      if (mounted) state = p;
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
        onChange: (_) async {
          final p = await PresenceService.fetchPartner(id);
          if (mounted) state = p;
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
