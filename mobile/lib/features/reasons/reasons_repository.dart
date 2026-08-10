import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One "reason I love you" note authored by one partner.
class LoveReason {
  LoveReason({
    required this.id,
    required this.author,
    required this.text,
    required this.createdAt,
  });

  factory LoveReason.fromJson(Map<String, dynamic> j) => LoveReason(
        id: JsonUtils.parseString(j['id']),
        author: JsonUtils.parseString(j['author']),
        text: JsonUtils.parseString(j['text']),
        createdAt: JsonUtils.parseDate(j['created_at']).toLocal(),
      );

  final String id;
  final String author;
  final String text;
  final DateTime createdAt;
}

class ReasonsRepository {
  ReasonsRepository._();

  static final _c = SupabaseService.client;

  static Future<List<LoveReason>> list(String coupleId) async {
    final res = await _c
        .from('love_reasons')
        .select()
        .eq('couple_id', coupleId)
        .order('created_at', ascending: false);
    return (res as List)
        .map((e) => LoveReason.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  static Future<void> add({
    required String coupleId,
    required String author,
    required String text,
  }) async {
    await _c.from('love_reasons').insert({
      'couple_id': coupleId,
      'author': author,
      'text': text.trim(),
    });
  }

  static Future<void> delete(String id) async {
    await _c.from('love_reasons').delete().eq('id', id);
  }

  static RealtimeChannel subscribe(String coupleId, void Function() onChange) {
    return _c
        .channel('love_reasons:$coupleId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'love_reasons',
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
