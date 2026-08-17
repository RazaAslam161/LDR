import 'dart:math';
import 'dart:typed_data';

import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum CapsuleUnlockMode { proximity, date, both }

enum CapsuleItemType { note, photo, voice }

CapsuleUnlockMode _modeFrom(String s) => CapsuleUnlockMode.values
    .firstWhere((e) => e.name == s, orElse: () => CapsuleUnlockMode.date);
CapsuleItemType _typeFrom(String s) => CapsuleItemType.values
    .firstWhere((e) => e.name == s, orElse: () => CapsuleItemType.note);

class Capsule {
  Capsule({
    required this.id,
    required this.coupleId,
    required this.title,
    required this.unlockMode,
    required this.createdAt,
    this.unlockDate,
    this.unlockedAt,
  });

  factory Capsule.fromJson(Map<String, dynamic> j) => Capsule(
        id: JsonUtils.parseString(j['id']),
        coupleId: JsonUtils.parseString(j['couple_id']),
        title: JsonUtils.parseString(j['title']),
        unlockMode: _modeFrom(
            JsonUtils.parseString(j['unlock_mode'], fallback: 'date'),),
        unlockDate: JsonUtils.parseDateOrNull(j['unlock_date'])?.toLocal(),
        unlockedAt: JsonUtils.parseDateOrNull(j['unlocked_at'])?.toLocal(),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
      );

  final String id;
  final String coupleId;
  final String title;
  final CapsuleUnlockMode unlockMode;
  final DateTime? unlockDate;
  final DateTime? unlockedAt;
  final DateTime createdAt;

  bool get isUnlocked => unlockedAt != null;

  /// Whether the DATE condition is satisfied right now (proximity is checked
  /// separately + client-side). For `proximity` mode the date is irrelevant.
  bool get dateConditionMet {
    switch (unlockMode) {
      case CapsuleUnlockMode.proximity:
        return true;
      case CapsuleUnlockMode.date:
      case CapsuleUnlockMode.both:
        final d = unlockDate;
        return d != null && DateTime.now().isAfter(d);
    }
  }

  bool get needsProximity =>
      unlockMode == CapsuleUnlockMode.proximity ||
      unlockMode == CapsuleUnlockMode.both;
}

class CapsuleItem {
  CapsuleItem({
    required this.id,
    required this.capsuleId,
    required this.authorId,
    required this.type,
    required this.createdAt,
    this.contentText,
    this.mediaUrl,
  });

  factory CapsuleItem.fromJson(Map<String, dynamic> j) => CapsuleItem(
        id: JsonUtils.parseString(j['id']),
        capsuleId: JsonUtils.parseString(j['capsule_id']),
        authorId: JsonUtils.parseString(j['author_id']),
        type: _typeFrom(JsonUtils.parseString(j['type'], fallback: 'note')),
        contentText: JsonUtils.parseStringOrNull(j['content_text']),
        mediaUrl: JsonUtils.parseStringOrNull(j['media_url']),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
      );

  final String id;
  final String capsuleId;
  final String authorId;
  final CapsuleItemType type;
  final String? contentText;
  final String? mediaUrl; // storage object path
  final DateTime createdAt;
}

/// All Time Capsule data access. Couple-scoped via RLS; items stay sealed
/// (un-SELECTable) until the parent capsule's `unlocked_at` is set.
class CapsuleRepository {
  CapsuleRepository._();

  static SupabaseClient get _c => SupabaseService.client;
  static const _bucket = 'capsule-media';

  static Future<List<Capsule>> list(String coupleId) async {
    final res = await _c
        .from('capsules')
        .select()
        .eq('couple_id', coupleId)
        .order('created_at', ascending: false);
    return (res as List)
        .map((e) => Capsule.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<Capsule> create({
    required String coupleId,
    required String title,
    required CapsuleUnlockMode mode,
    DateTime? unlockDate,
  }) async {
    final uid = SupabaseService.currentUserId;
    final res = await _c
        .from('capsules')
        .insert({
          'couple_id': coupleId,
          'title': title,
          'unlock_mode': mode.name,
          'unlock_date': unlockDate?.toUtc().toIso8601String(),
          'created_by': uid,
        })
        .select()
        .single();
    return Capsule.fromJson(res);
  }

  /// Counts of sealed items by type (no content) — powers blurred silhouettes
  /// before the capsule is opened.
  static Future<Map<CapsuleItemType, int>> sealSummary(String capsuleId) async {
    final res = await _c.rpc<dynamic>(
      'capsule_seal_summary',
      params: {'p_capsule_id': capsuleId},
    );
    final rows = res as List? ?? const [];
    final out = <CapsuleItemType, int>{};
    var skipped = 0;
    Object? firstError;
    StackTrace? firstStack;
    for (final row in rows) {
      try {
        final m = JsonUtils.asMap(row);
        out[_typeFrom(JsonUtils.parseString(m['item_type']))] =
            JsonUtils.parseInt(m['n']);
      } catch (e, st) {
        // Skip a malformed summary row rather than blanking the whole capsule
        // — but counted and reported below, never silently: a summary that
        // decodes N of M rows understates what the capsule holds. The report
        // carries the count and the error class only, no row contents.
        skipped++;
        firstError ??= e;
        firstStack ??= st;
      }
    }
    if (skipped > 0) {
      ErrorReporter.report(
        ParseShortfall('capsule seal summary',
            parsed: rows.length - skipped,
            of: rows.length,
            first: '${firstError.runtimeType}',),
        firstStack,
        kind: 'capsule',
      );
    }
    return out;
  }

  static Future<void> addNote(String capsuleId, String text) async {
    final uid = SupabaseService.currentUserId;
    await _c.from('capsule_items').insert({
      'capsule_id': capsuleId,
      'author_id': uid,
      'type': 'note',
      'content_text': text.trim(),
    });
  }

  static Future<void> addMedia({
    required String coupleId,
    required String capsuleId,
    required CapsuleItemType type,
    required Uint8List bytes,
    required String fileExtension,
    required String contentType,
    String? caption,
  }) async {
    final uid = SupabaseService.currentUserId;
    final rand = Random().nextInt(1 << 32).toRadixString(16);
    final path = '$coupleId/$capsuleId/${type.name}_$rand.$fileExtension';
    await _c.storage.from(_bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType),
        );
    await _c.from('capsule_items').insert({
      'capsule_id': capsuleId,
      'author_id': uid,
      'type': type.name,
      'media_url': path,
      'content_text': caption,
    });
  }

  /// Full items — only returns rows once the capsule is unlocked (RLS).
  static Future<List<CapsuleItem>> items(String capsuleId) async {
    final res = await _c
        .from('capsule_items')
        .select()
        .eq('capsule_id', capsuleId)
        .order('created_at');
    return (res as List)
        .map((e) => CapsuleItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Time-limited signed URL for a sealed media object (photo/voice playback).
  static Future<String> signedUrl(String path) =>
      _c.storage.from(_bucket).createSignedUrl(path, 60 * 60);

  /// Server-enforced unlock (date/both); proximity is client-verified first.
  static Future<Capsule> unlock(String capsuleId) async {
    final res = await _c.rpc<dynamic>(
      'unlock_capsule',
      params: {'p_capsule_id': capsuleId},
    );
    final row = res is List ? res.first : res;
    return Capsule.fromJson(Map<String, dynamic>.from(row as Map));
  }

  /// Live capsule changes (the unlock flips on both phones at the reunion).
  static RealtimeChannel subscribe(
    String coupleId,
    void Function() onChange,
  ) {
    return _c
        .channel('capsules:$coupleId', opts: RealtimeChannelConfig(private: true))
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'capsules',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (_) => onChange(),
        )
        .subscribe();
  }
}
