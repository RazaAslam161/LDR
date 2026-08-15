import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class VaultItem {
  VaultItem({
    required this.id,
    required this.type,
    required this.createdAt,
    this.content,
    this.mediaUrl,
  });

  factory VaultItem.fromJson(Map<String, dynamic> j) => VaultItem(
        id: JsonUtils.parseString(j['id']),
        type: JsonUtils.parseString(j['type'], fallback: 'note'),
        content: JsonUtils.parseStringOrNull(j['content']),
        mediaUrl: JsonUtils.parseStringOrNull(j['media_url']),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
      );

  final String id;
  final String type;
  final String? content;
  final String? mediaUrl;
  final DateTime createdAt;
}

/// Personal (owner-only) vault + 4-digit PIN. PIN hashing/verification + lockout
/// run server-side (bcrypt via pgcrypto) so the PIN is never compared on-device.
class VaultRepository {
  VaultRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  static Future<bool> hasPin() async {
    final res = await _c.rpc<dynamic>('has_vault_pin');
    return res == true;
  }

  static Future<void> setPin(String pin) =>
      _c.rpc<dynamic>('set_vault_pin', params: {'p_pin': pin});

  /// Returns 'ok' | 'wrong' | 'locked' | 'no_pin'.
  static Future<String> verifyPin(String pin) async {
    final res = await _c.rpc<dynamic>('verify_vault_pin', params: {'p_pin': pin});
    return res?.toString() ?? 'wrong';
  }

  static const _pageSize = 200;

  /// Everything in the personal vault, newest first, read a page at a time.
  ///
  /// The cursor is `created_at` rather than an offset: OFFSET makes the server
  /// walk rows it then discards, and it shifts under anything saved while the
  /// list is open.
  static Future<List<VaultItem>> items() async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return [];
    final out = <VaultItem>[];
    DateTime? cursor;
    while (true) {
      var q = _c.from('personal_vault_items').select().eq('owner_id', uid);
      if (cursor != null) {
        q = q.lt('created_at', cursor.toUtc().toIso8601String());
      }
      final res =
          await q.order('created_at', ascending: false).limit(_pageSize);
      out.addAll(res.map(VaultItem.fromJson));
      if (res.length < _pageSize) return out;
      cursor = out.last.createdAt;
    }
  }

  static Future<void> addNote(String content) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    await _c.from('personal_vault_items').insert({
      'owner_id': uid,
      'type': 'note',
      'content': content,
    });
  }

  /// Saves a reference to chat/touch media into the personal vault — ZERO bytes
  /// written to the device. The file stays in Supabase storage.
  ///
  /// [publicUrl] (couple_media, never expires) is stored as-is in `content`.
  /// [storagePath] (couple_intimate, private) is stored as `intimate:<path>`,
  /// and a fresh signed URL is generated on open. [label] is shown in the vault.
  static Future<void> saveMediaToVault({
    required String type, // 'saved_photo' | 'saved_video' | 'saved_voice'
    required String label,
    String? publicUrl,
    String? storagePath,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final content = storagePath != null ? 'intimate:$storagePath' : publicUrl;
    if (content == null) return;
    await _c.from('personal_vault_items').insert({
      'owner_id': uid,
      'type': type,
      'content': content,
      'media_url': label, // repurposed as the display label
    });
  }

  static Future<void> deleteItem(String id) async {
    await _c.from('personal_vault_items').delete().eq('id', id);
  }
}
