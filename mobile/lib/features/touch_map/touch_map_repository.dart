import 'dart:io';

import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BodyTouch {
  BodyTouch({
    required this.id,
    required this.fromUser,
    required this.zone,
    required this.type,
    required this.createdAt,
    this.posX,
    this.posY,
  });

  factory BodyTouch.fromJson(Map<String, dynamic> j) => BodyTouch(
        id: JsonUtils.parseString(j['id']),
        fromUser: JsonUtils.parseString(j['from_user']),
        zone: JsonUtils.parseString(j['body_zone']),
        type: JsonUtils.parseString(j['touch_type'], fallback: 'glow'),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
        posX: j['pos_x'] == null ? null : JsonUtils.parseDouble(j['pos_x']),
        posY: j['pos_y'] == null ? null : JsonUtils.parseDouble(j['pos_y']),
      );

  final String id;
  final String fromUser;
  final String zone;
  final String type;
  final DateTime createdAt;
  final double? posX; // normalized 0..1 (photo mode)
  final double? posY;

  bool isMine(String? uid) => fromUser == uid;
}

/// Ephemeral touch glows. Rows auto-expire (`expires_at`) — we never read old
/// ones; we just listen for live inserts and animate them.
class TouchMapRepository {
  TouchMapRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  static Future<void> sendTouch({
    required String coupleId,
    required String zone,
    required String type,
    double? posX,
    double? posY,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('body_touches').insert({
      'couple_id': coupleId,
      'from_user': uid,
      'body_zone': zone,
      'touch_type': type,
      if (posX != null) 'pos_x': posX,
      if (posY != null) 'pos_y': posY,
    });
  }

  /// Sets/refreshes the user's body photo (private bucket) and returns a signed
  /// URL to view a body photo at [path] (couple_intimate bucket, 1h).
  static Future<String?> signedBodyUrl(String? path) async {
    if (path == null) return null;
    try {
      return await _c.storage
          .from('couple_intimate')
          .createSignedUrl(path, 60 * 60);
    } catch (_) {
      return null;
    }
  }

  /// Uploads the user's body photo to the private couple_intimate bucket and
  /// stores its path on presence. Returns the storage path.
  static Future<String?> uploadBodyPhoto(String coupleId, File file) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return null;
    final path = '$coupleId/body/${uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    try {
      await _c.storage.from('couple_intimate').upload(
            path,
            file,
            fileOptions: const FileOptions(upsert: true),
          );
      return path;
    } catch (_) {
      return null;
    }
  }

  /// Clears a body photo — yours OR your partner's — via the couple-scoped
  /// `clear_body_photo` security-definer RPC. Nulls presence.body_photo_path
  /// and best-effort deletes the stored file, so the photo disappears for both
  /// partners. [targetUid] is whose photo to remove.
  static Future<void> deleteBodyPhoto(String targetUid) async {
    await _c.rpc<dynamic>('clear_body_photo', params: {'p_target': targetUid});
  }

  static RealtimeChannel subscribe(
    String coupleId,
    void Function(BodyTouch) onTouch,
  ) {
    return _c
        .channel('body_touches:$coupleId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'body_touches',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) => onTouch(BodyTouch.fromJson(payload.newRecord)),
        )
        .subscribe();
  }
}
