import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A link one of them sent the other.
class SharedReel {
  const SharedReel({
    required this.id,
    required this.url,
    required this.addedBy,
    required this.createdAt,
    required this.seenBy,
    this.source,
    this.note,
  });

  final String id;
  final String url;
  final String? addedBy;
  final String? source;
  final String? note;
  final DateTime createdAt;

  /// User ids that have opened it. The point of the feature is knowing whether
  /// the OTHER one has.
  final Set<String> seenBy;

  bool seen(String userId) => seenBy.contains(userId);

  static SharedReel fromJson(
    Map<String, dynamic> j, {
    Set<String> seenBy = const {},
  }) =>
      SharedReel(
        id: JsonUtils.parseString(j['id']),
        url: JsonUtils.parseString(j['url']),
        addedBy: JsonUtils.parseStringOrNull(j['added_by']),
        source: JsonUtils.parseStringOrNull(j['source']),
        note: JsonUtils.parseStringOrNull(j['note']),
        createdAt: JsonUtils.parseDate(j['created_at']).toUtc(),
        seenBy: seenBy,
      );
}

/// The couple's queue of things to watch.
///
/// Deliberately stores a LINK and nothing else — no thumbnail fetch, no page
/// scrape. Either would mean this app talking to Instagram on their behalf,
/// which is exactly what gets accounts banned, and neither is needed: the
/// value is "she sent me this and I haven't watched it yet".
class ReelQueueRepository {
  ReelQueueRepository._();

  static SupabaseClient get _c => SupabaseService.client;

  static const _columns = 'id,url,source,note,added_by,created_at';

  static Future<List<SharedReel>> fetch(String coupleId) async {
    final rows = await _c
        .from('shared_reels')
        .select(_columns)
        .eq('couple_id', coupleId)
        .eq('deleted', false)
        .order('created_at', ascending: false)
        .limit(200);

    final reels = [for (final r in rows as List) JsonUtils.asMap(r)];
    if (reels.isEmpty) return const [];

    final views = await _c
        .from('shared_reel_views')
        .select('reel_id,user_id')
        .inFilter('reel_id',
            [for (final r in reels) JsonUtils.parseString(r['id'])],);
    final seen = <String, Set<String>>{};
    for (final v in views as List) {
      final m = JsonUtils.asMap(v);
      seen
          .putIfAbsent(JsonUtils.parseString(m['reel_id']), () => {})
          .add(JsonUtils.parseString(m['user_id']));
    }
    return [
      for (final r in reels)
        SharedReel.fromJson(r,
            seenBy: seen[JsonUtils.parseString(r['id'])] ?? const {},),
    ];
  }

  /// Live queue. A link shared on her phone appears on his without a refresh,
  /// which is the whole reason this is not just a notes app.
  static Stream<List<SharedReel>> stream(String coupleId) {
    ManagedSubscription? reels;
    ManagedSubscription? views;
    late final StreamController<List<SharedReel>> controller;
    var loading = false;
    var delivered = false;

    Future<void> reload() async {
      if (loading) return;
      loading = true;
      try {
        final list = await fetch(coupleId);
        delivered = true;
        if (!controller.isClosed) controller.add(list);
      } catch (e, st) {
        ErrorReporter.report(e, st, kind: 'reels');
        // A failed FIRST load must fail the stream — swallowing it left
        // hasData false forever, which rendered as an infinite spinner with
        // "Couldn't load the list" unreachable. After one delivery, a
        // transient failure keeps showing the last good list instead.
        if (!delivered && !controller.isClosed) controller.addError(e);
      } finally {
        loading = false;
      }
    }

    controller = StreamController<List<SharedReel>>.broadcast(
      onListen: () async {
        reels = ManagedSubscription.start(
          () => RealtimeService.coupleTable(
            channelName: 'reels:$coupleId',
            table: 'shared_reels',
            coupleId: coupleId,
            onChange: (_) => unawaited(reload()),
          ),
        );
        // shared_reel_views has no couple_id; RLS still scopes delivery.
        views = ManagedSubscription.start(
          () => _c
              .channel('reel-views:$coupleId')
              .onPostgresChanges(
                event: PostgresChangeEvent.all,
                schema: 'public',
                table: 'shared_reel_views',
                callback: (_) => unawaited(reload()),
              )
              .subscribe(),
        );
        await reload();
      },
      onCancel: () {
        reels?.dispose();
        views?.dispose();
        reels = null;
        views = null;
      },
    );
    return controller.stream;
  }

  static Future<void> add({
    required String coupleId,
    required String addedBy,
    required String url,
    String? source,
    String? note,
  }) =>
      _c.from('shared_reels').insert({
        'couple_id': coupleId,
        'added_by': addedBy,
        'url': url,
        if (source != null) 'source': source,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      });

  /// Marks it seen by [userId]. Idempotent — opening a reel twice is normal.
  static Future<void> markSeen(String reelId, String userId) async {
    try {
      await _c.from('shared_reel_views').upsert({
        'reel_id': reelId,
        'user_id': userId,
      });
    } catch (e) {
      // A link that opened but did not record is a cosmetic loss, and throwing
      // here would surface an error over a video the user is already watching.
      debugPrint('[reels] markSeen: ${e.runtimeType}');
    }
  }

  static Future<void> remove(String reelId) =>
      _c.from('shared_reels').update({'deleted': true}).eq('id', reelId);
}
