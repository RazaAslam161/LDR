import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
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
  static const _bucket = privateBucket;

  static const _columns = 'id,storage_path,thumb_path,uploaded_by,mime_type,'
      'width,height,created_at,delete_requested,delete_requested_by,'
      'delete_refused_count';

  /// The last list this couple's grid painted, for the life of the process.
  ///
  /// Leaving the gallery disposes the window, so coming back built a new one,
  /// a new stream and a new fetch — and the first thing anyone saw on the way
  /// back in was a full-screen spinner over pictures the phone still had
  /// signed, decoded and on disk. The grid takes this as its initialData and
  /// paints on frame one; the fetch still runs underneath and replaces it, so
  /// nothing here is ever the last word on what exists.
  static final Map<String, List<GalleryItem>> _remembered = {};

  static List<GalleryItem>? lastSnapshot(String coupleId) =>
      _remembered[coupleId];

  /// Sign-out and unpair. These rows name the couple's storage paths, and
  /// MediaUrls still holds live 24-hour URLs for them — repainting them for
  /// whoever signs in next is the same leak GalleryScreen.clearFailedUploads
  /// exists to stop.
  static void forgetSnapshots() => _remembered.clear();

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

  static const pageSize = 500;

  /// One page for a caller that must see EVERYTHING — the data export walks
  /// this to exhaustion, because [fetch]'s 500 cap is a grid decision and an
  /// export truncated at it would be silent loss. Same select and order as
  /// [fetch]; the cursor is `created_at` rather than an offset, exactly as
  /// VaultRepository.items() pages, and for the same reasons. No URL warming:
  /// the export signs originals itself, and warming thousands of grid thumbs
  /// would be pure waste.
  static Future<List<GalleryItem>> fetchPage(
    String coupleId, {
    DateTime? before,
  }) async {
    var q = _c
        .from('gallery_items')
        .select(_columns)
        .eq('couple_id', coupleId)
        .eq('deleted', false);
    if (before != null) {
      q = q.lt('created_at', before.toUtc().toIso8601String());
    }
    final rows = await q.order('created_at', ascending: false).limit(pageSize);
    return [
      for (final r in rows as List) GalleryItem.fromJson(JsonUtils.asMap(r)),
    ];
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
  /// A live grid the caller can also page BACKWARDS.
  ///
  /// [stream] seeds from [fetch], which is capped at 500 — deliberately, since
  /// it is a grid decision — and nothing could reach past it. A couple who
  /// share a picture a day hit that inside two years and their earliest
  /// photographs simply stopped existing as far as the app was concerned.
  ///
  /// The vocabulary is SharedMediaWindow's, because the question is the same
  /// one: busy while a page is in flight, atEnd once a short page has proved
  /// there is nothing behind it, failed so the screen can offer a retry rather
  /// than a silence.
  static GalleryWindow window(String coupleId) => GalleryWindow._(coupleId);

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
  /// What the bucket itself will accept, mirrored here.
  ///
  /// `couple_intimate` is created with `file_size_limit = 104857600`, and
  /// without this check the only thing that enforced it was storage answering
  /// 413 after the whole file had been pushed up a phone uplink — which the
  /// screen then reported as "check your connection" and offered to retry
  /// forever. Keep in step with the bucket if that limit ever moves.
  static const maxUploadBytes = 100 * 1024 * 1024;

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
    // Before the thumbnail, not after: a poster for a file that can never be
    // stored is an orphaned object nothing will ever reference or reap.
    if (bytes.lengthInBytes > maxUploadBytes) {
      throw GalleryTooLarge(bytes.lengthInBytes);
    }

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

/// A file the bucket will refuse on size, caught before it is sent.
///
/// Its own type because the screen has to treat it differently from every
/// other upload failure: no amount of retrying makes a 200 MB video fit, so
/// offering Retry for it is a control that cannot work.
class GalleryTooLarge implements Exception {
  const GalleryTooLarge(this.bytes);

  final int bytes;

  /// Whole megabytes, for a sentence a person can act on.
  int get megabytes => (bytes / (1024 * 1024)).round();

  @override
  String toString() => 'GalleryTooLarge';
}


/// A [GalleryRepository.stream] with a back-page.
///
/// Holds the live map itself rather than wrapping the closure-scoped one in
/// `stream()`, because a page loaded from underneath has to merge into exactly
/// the map the realtime deltas patch — two maps would let a deleted picture
/// come back through the older page.
class GalleryWindow {
  GalleryWindow._(this.coupleId);

  final String coupleId;

  final Map<String, GalleryItem> _byId = {};
  ManagedSubscription? _sub;
  StreamController<List<GalleryItem>>? _controller;

  /// A page is in flight.
  bool busy = false;

  /// A short page has proved there is nothing behind this one.
  bool atEnd = false;

  /// The last page threw. The pictures already on screen are still correct.
  Object? failed;

  /// How far back the pages have reached.
  ///
  /// Held separately, NOT derived as the minimum of [_byId]: realtime patches
  /// that map and is not window-scoped, so a delete of the oldest picture
  /// moved a derived cursor FORWARD and the next page skipped every row
  /// between the two — silently, and permanently, since nothing re-asks.
  /// This only ever moves backwards, as a cursor must.
  DateTime? _floor;

  DateTime? get _cursor {
    final floor = _floor;
    if (_byId.isEmpty) return floor;
    final min = _byId.values
        .map((i) => i.createdAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    if (floor == null || min.isBefore(floor)) return min;
    return floor;
  }

  List<GalleryItem> _snapshot() {
    final live = _byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final snap = List<GalleryItem>.unmodifiable(live);
    GalleryRepository._remembered[coupleId] = snap;
    return snap;
  }

  void _emit() {
    final c = _controller;
    if (c != null && !c.isClosed) c.add(_snapshot());
  }

  Future<void> _apply(PostgresChangePayload p) async {
    try {
      if (p.eventType == PostgresChangeEvent.delete) {
        final id = p.oldRecord['id'];
        if (id != null) _byId.remove(JsonUtils.parseString(id));
      } else {
        final row = GalleryItem.fromJson(p.newRecord);
        if (p.newRecord['deleted'] == true) {
          _byId.remove(row.id);
        } else {
          _byId[row.id] = row;
          await GalleryRepository._warm([row]);
        }
      }
    } catch (e) {
      debugPrint('[gallery] delta: ${e.runtimeType}');
      return;
    }
    _emit();
  }

  Stream<List<GalleryItem>> get stream {
    final existing = _controller;
    if (existing != null) return existing.stream;
    final c = _controller = StreamController<List<GalleryItem>>.broadcast(
      onListen: () async {
        _sub = ManagedSubscription.start(
          () => RealtimeService.coupleTable(
            channelName: 'gallery:$coupleId',
            table: 'gallery_items',
            coupleId: coupleId,
            onChange: (p) => unawaited(_apply(p)),
          ),
        );
        try {
          for (final i in await GalleryRepository.fetch(coupleId)) {
            _byId.putIfAbsent(i.id, () => i);
          }
          _emit();
        } catch (e) {
          final ctrl = _controller;
          if (ctrl != null && !ctrl.isClosed) ctrl.addError(e);
        }
      },
      onCancel: dispose,
    );
    return c.stream;
  }

  /// One page older. A no-op while busy, at the end, or before the seed has
  /// landed — a null cursor would ask for everything.
  Future<void> more() async {
    final before = _cursor;
    if (busy || atEnd || before == null) return;
    busy = true;
    failed = null;
    try {
      final page =
          await GalleryRepository.fetchPage(coupleId, before: before);
      atEnd = page.length < GalleryRepository.pageSize;
      // Recorded from the PAGE, not from the map, and never allowed forward.
      for (final i in page) {
        final f = _floor;
        if (f == null || i.createdAt.isBefore(f)) _floor = i.createdAt;
      }
      var added = false;
      for (final i in page) {
        // putIfAbsent, never assignment: a realtime delta that arrived while
        // this page was on the wire is NEWER than the row the page carries.
        if (_byId.containsKey(i.id)) continue;
        _byId[i.id] = i;
        added = true;
      }
      if (added) {
        // Signed before it paints, exactly as the seed and the deltas are.
        await GalleryRepository._warm(page);
        _emit();
      }
    } catch (e, st) {
      failed = e;
      // `failed` had no reader anywhere, so a back-page that threw was the one
      // silent failure path in this file — every sibling logs or addErrors.
      debugPrint('[gallery] page failed: ${e.runtimeType}');
      ErrorReporter.report(e, st, kind: 'gallery-page');
    } finally {
      busy = false;
    }
  }

  void dispose() {
    _sub?.dispose();
    _sub = null;
    final c = _controller;
    _controller = null;
    unawaited(c?.close());
  }
}
