import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/media_urls.dart';

/// Encrypted media, from a private bucket to a painted frame.
///
/// This is the foundation the vault and Memory Threads BOTH sit on. Both stored
/// encrypted media as `bytea` inline in a database row, which is why both show
/// loading wheels everywhere while chat does not — every tile costs a fetch of
/// the full-size ciphertext and a decrypt before it can paint anything. Building
/// it once is deliberate: two copies of this drift, and the half that drifts is
/// always the cache-key discipline that makes it fast.
///
/// Three layers, and the boundaries between them are the whole design:
///
///   L3  Flutter's own ImageCache, keyed by (provider identity, resize bounds)
///   L2  plaintext, in RAM only, keyed by (key epoch, bucket/path)
///   L1  CIPHERTEXT, on disk, its own store
///
/// **Plaintext never touches disk.** The vault decrypts to
/// `getTemporaryDirectory()` and deletes in `dispose()` — but backgrounding is
/// exactly when Android kills the process, so `dispose` frequently never runs,
/// and the app raises its disguise cover on background specifically because
/// someone may be looking. Ciphertext at rest is as safe as ciphertext in
/// Postgres, and it lets `flutter_cache_manager` be reused verbatim.
///
/// **L1 gets its OWN store, not `DefaultCacheManager`.** That singleton is
/// `maxNrOfCacheObjects: 200` shared with every `CachedNetworkImage` in the
/// app, so ten minutes of chat scrolling would evict this feature completely
/// and permanently.
class EncryptedMediaCache {
  EncryptedMediaCache._();

  /// Ciphertext on disk. 90 days and 1500 objects: a couple's whole memory
  /// timeline plus its vault, which is the point — this is the layer that makes
  /// the second open instant.
  static final CacheManager _l1 = CacheManager(
    Config(
      'milesCipherMedia',
      stalePeriod: const Duration(days: 90),
      maxNrOfCacheObjects: 1500,
    ),
  );

  /// Plaintext, RAM only, bounded by BYTES rather than by entry count.
  ///
  /// A 400px tile and a 12-megapixel original differ by three orders of
  /// magnitude, so "96 tiles and 3 fulls" is a budget that is either far too
  /// loose or far too tight depending on what the user actually opened. One
  /// byte ceiling self-balances and cannot be wrong.
  static const int _l2MaxBytes = 48 * 1024 * 1024;

  /// Insertion-ordered, so the first key is the least recently used — every
  /// read re-inserts.
  static final Map<String, _Plain> _l2 = <String, _Plain>{};
  static int _l2Bytes = 0;

  /// One fetch per path, however many surfaces ask at once. A grid and a pager
  /// opening on the same photo previously did the download and the decrypt
  /// twice.
  static final Map<String, Future<Uint8List>> _inFlight = {};

  static bool _wired = false;

  /// Clears everything plaintext whenever the key that produced it could have
  /// changed. Idempotent; called from the first cache use.
  static void _wire() {
    if (_wired) return;
    _wired = true;
    CryptoCore.keyEpoch.addListener(clear);
  }

  static String _key(String bucket, String path) =>
      '${CryptoCore.keyEpoch.value}|$bucket/$path';

  /// The decrypted bytes for [path], from RAM, then disk, then the network.
  ///
  /// Returns the **identical** [Uint8List] instance on every call for one path.
  /// That is not an optimisation: `MemoryImage.==` compares its bytes field by
  /// REFERENCE, so handing out a copy silently produces a second provider, a
  /// second full decode, and a second ImageCache entry while the first is still
  /// resident.
  static Future<Uint8List> bytes({
    required String bucket,
    required String path,
    required String associatedData,
  }) {
    _wire();
    final k = _key(bucket, path);
    final hit = _l2.remove(k);
    if (hit != null) {
      _l2[k] = hit; // re-insert: most recently used
      return Future<Uint8List>.value(hit.bytes);
    }
    final flying = _inFlight[k];
    if (flying != null) return flying;

    final job = _load(bucket, path, associatedData).then((plain) {
      _admit(k, plain);
      return plain;
    }).whenComplete(() => _inFlight.remove(k));
    _inFlight[k] = job;
    return job;
  }

  /// A provider for the timeline cover, bounded to the width it is painted at.
  ///
  /// [decodeWidth] must be computed ONCE per screen and shared by every card,
  /// or each card's slightly different width becomes its own ImageCache entry.
  static Future<ImageProvider> coverProvider({
    required String path,
    required String associatedData,
    required int decodeWidth,
    String bucket = intimateBucket,
  }) async {
    final raw = await bytes(
        bucket: bucket, path: path, associatedData: associatedData,);
    return _provider(bucket, path, raw, decodeWidth);
  }

  /// A provider for the 400px tile — the gallery grid, the pager underlay and
  /// the filmstrip all paint this one.
  ///
  /// **Unbounded, deliberately.** The object is already its own bound at 400px,
  /// so leaving the resize off is what lets three surfaces share ONE decode of
  /// one instance. Adding a width here would give each of them its own key.
  static Future<ImageProvider> tileProvider({
    required String path,
    required String associatedData,
    String bucket = intimateBucket,
  }) async {
    final raw = await bytes(
        bucket: bucket, path: path, associatedData: associatedData,);
    return _provider(bucket, path, raw, null);
  }

  /// A provider for the original. [decodeWidth] null mounts it unbounded, which
  /// is what the zoom layer wants and what nothing else should ask for.
  static Future<ImageProvider> fullProvider({
    required String path,
    required String associatedData,
    int? decodeWidth,
    String bucket = intimateBucket,
  }) async {
    final raw = await bytes(
        bucket: bucket, path: path, associatedData: associatedData,);
    return _provider(bucket, path, raw, decodeWidth);
  }

  /// Builds — and remembers — the provider over [raw].
  ///
  /// Remembering matters as much as building: `MemoryImage.obtainKey` returns
  /// `this`, so every painted photo is strongly reachable from
  /// `PaintingBinding.instance.imageCache` (1000 entries / 100 MiB, NOT device
  /// scaled — the same on a 2 GB IN2015). Dropping an L2 entry without evicting
  /// its providers frees nothing at all.
  ///
  /// `height` is never passed anywhere. Passing both dimensions makes the key
  /// depend on both, so a square grid tile and a width-only underlay miss each
  /// other even when the width agrees. One dimension, always; `BoxFit` shapes.
  static ImageProvider _provider(
    String bucket,
    String path,
    Uint8List raw,
    int? decodeWidth,
  ) {
    final entry = _l2[_key(bucket, path)];
    final memory = MemoryImage(raw);
    // Explicitly typed: MemoryImage and ResizeImage are ImageProvider over
    // different key types, so an inferred ternary lands on Object.
    final ImageProvider provider = decodeWidth == null
        ? memory
        : ResizeImage(memory, width: decodeWidth);
    entry?.providers.add(provider);
    return provider;
  }

  static Future<Uint8List> _load(
    String bucket,
    String path,
    String associatedData,
  ) async {
    final packed = await _cipherBytes(bucket, path);
    return CryptoCore.decryptBytesOffThread(
      packed,
      associatedData: associatedData,
    );
  }

  /// The ciphertext, from L1 or the network.
  static Future<Uint8List> _cipherBytes(String bucket, String path) async {
    final cacheKey = '$bucket/$path';
    final cached = await _l1.getFileFromCache(cacheKey);
    if (cached != null) return cached.file.readAsBytes();

    var url = MediaUrls.cached(bucket, path) ?? await MediaUrls.sign(bucket, path);
    if (url == null) throw const MediaTransient();
    try {
      final file = await _l1.getSingleFile(url, key: cacheKey);
      return file.readAsBytes();
    } catch (e) {
      // A 403 has to have an owner. MediaUrls.refresh's own doc names the case:
      // "this handset's clock is simply wrong, and a phone that is an hour fast
      // hands out URLs it believes are fresh and the server believes are dead".
      // Without a retry here that phone renders every photo as MISSING — a flat
      // lie that would make someone believe their pictures are gone.
      final status = _statusOf(e);
      if (status == 404) throw const MediaMissing();
      if (status != 401 && status != 403) rethrow;
      url = await MediaUrls.refresh(bucket, path);
      if (url == null) throw const MediaTransient();
      try {
        final file = await _l1.getSingleFile(url, key: cacheKey);
        return file.readAsBytes();
      } catch (e2) {
        // Surviving one refresh is its own state, and it is NOT "missing".
        if (_statusOf(e2) == 404) throw const MediaMissing();
        throw const MediaTransient();
      }
    }
  }

  static int? _statusOf(Object e) {
    if (e is HttpExceptionWithStatus) return e.statusCode;
    // flutter_cache_manager wraps some failures; the code is in the message.
    final m = RegExp(r'\b(40[13]|404)\b').firstMatch(e.toString());
    return m == null ? null : int.parse(m.group(1)!);
  }

  static void _admit(String key, Uint8List plain) {
    _l2[key] = _Plain(plain);
    _l2Bytes += plain.lengthInBytes;
    while (_l2Bytes > _l2MaxBytes && _l2.length > 1) {
      final oldest = _l2.keys.first;
      _evict(oldest);
    }
  }

  static void _evict(String key) {
    final gone = _l2.remove(key);
    if (gone == null) return;
    _l2Bytes -= gone.bytes.lengthInBytes;
    for (final p in gone.providers) {
      PaintingBinding.instance.imageCache.evict(p, includeLive: true);
    }
  }

  /// Seeds L1 with ciphertext this device just produced.
  ///
  /// Without it, uploading a photo and then looking at it downloads the bytes
  /// that were in memory a second earlier.
  static Future<void> seed({
    required String bucket,
    required String path,
    required Uint8List packed,
  }) async {
    try {
      await _l1.putFile('$bucket/$path', packed,
          key: '$bucket/$path', fileExtension: 'enc',);
    } catch (e) {
      debugPrint('[media] seed failed: ${e.runtimeType}');
    }
  }

  /// Drops every decrypted byte this process holds.
  ///
  /// L2 alone is not enough and this is the subtlest rule in the file: every
  /// photo that has been PAINTED is still strongly held by Flutter's ImageCache
  /// and its live-image set, so clearing only the map leaves the couple's
  /// photographs in RAM behind the disguise cover — which is precisely the
  /// moment the design claims they are gone.
  ///
  /// L1 is left alone. It is ciphertext, and re-downloading it on every cover
  /// raise would be a great deal of traffic to protect nothing.
  static void clear() {
    for (final e in _l2.values) {
      for (final p in e.providers) {
        PaintingBinding.instance.imageCache.evict(p, includeLive: true);
      }
    }
    _l2.clear();
    _l2Bytes = 0;
    _inFlight.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  /// Ciphertext too — sign-out, not a cover raise.
  static Future<void> clearAll() async {
    clear();
    try {
      await _l1.emptyCache();
    } catch (e) {
      debugPrint('[media] L1 empty failed: ${e.runtimeType}');
    }
  }

  @visibleForTesting
  static int get plaintextBytes => _l2Bytes;

  @visibleForTesting
  static int get plaintextEntries => _l2.length;
}

/// One decrypted object, plus every provider built over it, so eviction can
/// take the ImageCache entries with it.
class _Plain {
  _Plain(this.bytes);
  final Uint8List bytes;
  final List<ImageProvider> providers = [];
}

/// Why a piece of media could not be shown.
///
/// Deliberately separate from a crypto failure: these are about the OBJECT, and
/// the difference between them is the difference between "try again" and "your
/// photograph is gone", which is not a distinction to get wrong.
sealed class MediaFailure implements Exception {
  const MediaFailure();
  String get message;
}

/// A 403 that survived one re-sign, or an object that could not be signed at
/// all. Never phrased as missing.
class MediaTransient extends MediaFailure {
  const MediaTransient();
  @override
  String get message => "Couldn't reach this photo. Try again.";
}

/// A 404, and only a 404.
class MediaMissing extends MediaFailure {
  const MediaMissing();
  @override
  String get message =>
      "This photo's file is missing. The memory is fine; the picture didn't "
      'make it.';
}
