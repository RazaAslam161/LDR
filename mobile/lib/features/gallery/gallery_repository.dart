import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/media/thumbnails.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One picture in the couple's shared gallery.
class GalleryItem {
  const GalleryItem({
    required this.id,
    required this.storagePath,
    required this.createdAt,
    this.thumbPath,
    this.uploadedBy,
    this.mimeType = 'image/jpeg',
    this.width,
    this.height,
    this.deleteRequested = false,
    this.deleteRequestedBy,
    this.deleteRefusedCount = 0,
  });

  /// Someone has asked to remove this and is waiting on the other one.
  final bool deleteRequested;
  final String? deleteRequestedBy;

  /// How many times the OTHER partner has said no.
  ///
  /// Withdrawing your own request does not count — that is a change of mind,
  /// not a refusal. At [refusalLimit] the item can no longer be asked about at
  /// all: without a cap, "it stays if one of you says no" is true of any single
  /// round and false over a week, because nothing stops the same picture being
  /// put up for deletion again every evening.
  final int deleteRefusedCount;

  static const refusalLimit = 3;

  /// Settled. Kept, and no longer up for discussion.
  bool get deleteSettled => deleteRefusedCount >= refusalLimit;

  /// True when the answer is THIS person's to give.
  bool awaitingMe(String me) => deleteRequested && deleteRequestedBy != me;

  final String id;
  final String storagePath;
  final String? thumbPath;
  final String? uploadedBy;
  final String mimeType;
  final DateTime createdAt;

  /// Known before the bytes arrive, which is the whole point of storing them:
  /// the tile reserves the right shape immediately, so the grid never reflows
  /// as pictures land. Previews staying still is a schema property, not a
  /// widget trick.
  final int? width;
  final int? height;

  double get aspect =>
      (width == null || height == null || height == 0) ? 1 : width! / height!;

  /// What the grid paints. Falls back to the original for rows written before
  /// a thumbnail existed, exactly as the chat pipeline does.
  String get gridPath => thumbPath ?? storagePath;

  bool get isVideo => mimeType.startsWith('video/');

  static GalleryItem fromJson(Map<String, dynamic> j) => GalleryItem(
        id: JsonUtils.parseString(j['id']),
        storagePath: JsonUtils.parseString(j['storage_path']),
        thumbPath: JsonUtils.parseStringOrNull(j['thumb_path']),
        uploadedBy: JsonUtils.parseStringOrNull(j['uploaded_by']),
        mimeType: JsonUtils.parseStringOrNull(j['mime_type']) ?? 'image/jpeg',
        createdAt: JsonUtils.parseDate(j['created_at']).toUtc(),
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        deleteRequested: (j['delete_requested'] as bool?) ?? false,
        deleteRequestedBy:
            JsonUtils.parseStringOrNull(j['delete_requested_by']),
        deleteRefusedCount: (j['delete_refused_count'] as num?)?.toInt() ?? 0,
      );
}

/// The shared gallery: both partners upload, both see everything, immediately.
///
/// Deliberately NOT encrypted, and that is the entire reason it is fast. The
/// vault stored ciphertext, so nothing could paint until the whole object had
/// been fetched and run through XChaCha20 — which rules out range requests, CDN
/// caching, progressive decode, and any use of the disk image cache, and puts a
/// decrypt on the UI isolate per tile. Those spinners were the design working
/// as written. Plaintext objects behind signed URLs let this reuse the chat
/// pipeline verbatim, which is already the fast one in this app.
///
/// The cost is real and is recorded in 20260601008000: Supabase can read these
/// pictures. Any copy claiming otherwise has to change with it.
class GalleryRepository {
  GalleryRepository._();

  static SupabaseClient get _c => SupabaseService.client;
  static const _bucket = intimateBucket;

  static const _columns = 'id,storage_path,thumb_path,uploaded_by,mime_type,'
      'width,height,created_at,delete_requested,delete_requested_by,'
      'delete_refused_count';

  static String _originalPath(String coupleId, String id, String ext) =>
      '$coupleId/gallery/$id.$ext';
  static String _thumbPath(String coupleId, String id) =>
      '$coupleId/gallery/thumb/$id.jpg';

  /// Newest first, not deleted. Signed URLs for the whole page are warmed in
  /// ONE request before this returns, so the grid paints from a synchronous
  /// cache lookup instead of a round trip per tile.
  static Future<List<GalleryItem>> fetch(String coupleId) async {
    final rows = await _c
        .from('gallery_items')
        .select(_columns)
        .eq('couple_id', coupleId)
        .eq('deleted', false)
        .order('created_at', ascending: false)
        .limit(500);

    final items = [
      for (final r in rows as List) GalleryItem.fromJson(JsonUtils.asMap(r)),
    ];
    await _warm(items);
    return items;
  }

  /// One createSignedUrls call for every path the grid is about to ask for.
  /// Signing per tile is a network round trip behind every picture.
  static Future<void> _warm(List<GalleryItem> items) =>
      MediaUrls.warm(_bucket, items.map((i) => i.gridPath));

  /// Warms the ORIGINALS around [index] so opening the pager is instant.
  static Future<void> warmOriginals(List<GalleryItem> items, int index) {
    final near = <String>[];
    for (var i = index - 2; i <= index + 2; i++) {
      if (i >= 0 && i < items.length) near.add(items[i].storagePath);
    }
    return MediaUrls.warm(_bucket, near);
  }

  /// Live grid. Seeds once, then patches per change — a partner's upload
  /// appears without a refresh, which is the difference between a shared
  /// gallery and two galleries.
  static Stream<List<GalleryItem>> stream(String coupleId) {
    final byId = <String, GalleryItem>{};
    ManagedSubscription? sub;
    late final StreamController<List<GalleryItem>> controller;

    List<GalleryItem> snapshot() {
      final live = byId.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return List.unmodifiable(live);
    }

    Future<void> apply(PostgresChangePayload p) async {
      try {
        if (p.eventType == PostgresChangeEvent.delete) {
          final id = p.oldRecord['id'];
          if (id != null) byId.remove(JsonUtils.parseString(id));
        } else {
          final row = GalleryItem.fromJson(p.newRecord);
          if (p.newRecord['deleted'] == true) {
            byId.remove(row.id);
          } else {
            byId[row.id] = row;
            // Sign before it paints, or the newest tile is the one that shows
            // a placeholder.
            await _warm([row]);
          }
        }
      } catch (e) {
        debugPrint('[gallery] delta: ${e.runtimeType}');
        return;
      }
      if (!controller.isClosed) controller.add(snapshot());
    }

    controller = StreamController<List<GalleryItem>>.broadcast(
      onListen: () async {
        sub = ManagedSubscription.start(
          () => RealtimeService.coupleTable(
            channelName: 'gallery:$coupleId',
            table: 'gallery_items',
            coupleId: coupleId,
            onChange: (p) => unawaited(apply(p)),
          ),
        );
        try {
          for (final i in await fetch(coupleId)) {
            byId.putIfAbsent(i.id, () => i);
          }
          if (!controller.isClosed) controller.add(snapshot());
        } catch (e) {
          if (!controller.isClosed) controller.addError(e);
        }
      },
      onCancel: () {
        sub?.dispose();
        sub = null;
      },
    );
    return controller.stream;
  }

  /// Uploads one picture: thumbnail first, then the original, then the row.
  ///
  /// That order matters for the same reason it does in `thumb_backfill` — a row
  /// visible before its objects is a tile that 404s, permanently, because
  /// nothing re-derives it. The ORIGINAL is uploaded byte-for-byte: re-encoding
  /// to save space would be a quality drop the user did not ask for, and the
  /// thumbnail already covers the cost of showing it small.
  static Future<GalleryItem> upload({
    required String coupleId,
    required String uploadedBy,
    required File file,
    String mimeType = 'image/jpeg',
  }) async {
    final id = _uuid();
    final ext = _extFor(mimeType);
    final original = _originalPath(coupleId, id, ext);
    final bytes = await file.readAsBytes();

    String? thumbPath;
    int? w;
    int? h;
    Uint8List? poster;

    if (mimeType.startsWith('video/')) {
      // A video has no poster unless one is MADE. `deriveImage` runs
      // img.decodeImage, which returns null for an mp4 — so a video uploaded
      // through the image path got thumb_path = null, `gridPath` fell back to
      // the .mp4 itself, and the grid handed a video file to
      // CachedNetworkImage. That is not a slow preview; it is a tile that can
      // never paint anything, ever.
      poster = await Thumbnails.forVideo(file);
    } else {
      final derived = await deriveImage(bytes);
      if (derived != null) {
        poster = derived.tile;
        w = derived.width;
        h = derived.height;
      }
    }

    if (poster != null) {
      thumbPath = _thumbPath(coupleId, id);
      await _c.storage.from(_bucket).uploadBinary(
            thumbPath,
            poster,
            fileOptions: const FileOptions(
              contentType: 'image/jpeg',
              cacheControl: '31536000',
            ),
          );
    }

    await _c.storage.from(_bucket).uploadBinary(
          original,
          bytes,
          fileOptions: FileOptions(
            contentType: mimeType,
            cacheControl: '31536000',
          ),
        );

    try {
      final row = await _c
          .from('gallery_items')
          .insert({
            'id': id,
            'couple_id': coupleId,
            'uploaded_by': uploadedBy,
            'storage_path': original,
            if (thumbPath != null) 'thumb_path': thumbPath,
            'mime_type': mimeType,
            if (w != null) 'width': w,
            if (h != null) 'height': h,
            'byte_size': bytes.lengthInBytes,
          })
          .select(_columns)
          .single();
      return GalleryItem.fromJson(row);
    } catch (_) {
      await _remove([original, if (thumbPath != null) thumbPath]);
      rethrow;
    }
  }

  /// Ask to remove these. Nothing disappears yet — the other partner answers.
  ///
  /// Batch by design: the selection is "these eleven", and eleven round trips
  /// would be eleven chances to half-apply. All three verbs take the whole set
  /// and resolve it in one statement.
  static Future<int> requestDelete(List<String> ids) =>
      _rpc('gallery_request_delete', ids);

  /// Call it off. EITHER partner may, including whoever asked — changing your
  /// mind must not need permission.
  static Future<int> cancelDelete(List<String> ids) =>
      _rpc('gallery_cancel_delete', ids);

  /// Agree to your partner's request. The RPC refuses the rows you asked about
  /// yourself; that one condition is the whole guarantee and cannot live here.
  static Future<int> confirmDelete(List<String> ids) =>
      _rpc('gallery_confirm_delete', ids);

  static Future<int> _rpc(String fn, List<String> ids) async {
    if (ids.isEmpty) return 0;
    final n = await _c.rpc<dynamic>(fn, params: {'p_ids': ids});
    return (n as num?)?.toInt() ?? 0;
  }

  static Future<void> _remove(List<String> paths) async {
    try {
      await _c.storage.from(_bucket).remove(paths);
    } catch (e) {
      debugPrint('[gallery] cleanup failed: ${e.runtimeType}');
    }
  }

  static String _extFor(String mime) => switch (mime) {
        'image/png' => 'png',
        'image/webp' => 'webp',
        'video/mp4' => 'mp4',
        'video/quicktime' => 'mov',
        _ => 'jpg',
      };

  /// v4 from [Random.secure], like every other id in this app that becomes a
  /// storage path. A time-derived id would be guessable, and these sit under a
  /// prefix whose only other protection is the signed URL.
  static String _uuid() {
    final random = Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
