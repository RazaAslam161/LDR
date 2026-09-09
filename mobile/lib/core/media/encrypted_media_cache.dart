import 'dart:async';
import 'dart:io';

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

  /// Caps the decoded-image cache at what this phone can spare.
  ///
  /// Flutter's default is 100 MiB on every device, which on a 2 GB handset is
  /// the difference between staying resident in the background and being the
  /// first thing the OS kills. Scaled to RAM — a 48th of it, floored at 32 MiB
  /// so a screenful of tiles never thrashes, and never above the default. A
  /// phone that will not say how much it has keeps the default.
  static Future<void> boundImageCache() async {
    try {
      final info = await File('/proc/meminfo').readAsString();
      final kb = RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(info)?.group(1);
      if (kb == null) {
        debugPrint('[image-cache] MemTotal missing from /proc/meminfo');
        return;
      }
      final bytes = (int.parse(kb) * 1024 ~/ 48).clamp(32 << 20, 100 << 20);
      PaintingBinding.instance.imageCache.maximumSizeBytes = bytes;
    } catch (e) {
      debugPrint(
          '[image-cache] meminfo unreadable (${e.runtimeType}); default kept',);
    }
  }

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
    List<int>? keyOverride,
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

    final gen = _generation;
    late final Future<Uint8List> job;
    job = _load(bucket, path, associatedData, keyOverride).then((plain) {
      // The caller asked for these bytes and gets them either way — it is the
      // CACHE that must not be repopulated across a clear. See [clear].
      if (gen == _generation) _admit(k, plain);
      return plain;
      // identical, not a bare remove: `clear()` empties this map, so a request
      // arriving after it installs a SECOND job under the same key — and the
      // first job finishing would otherwise delete the second one's entry,
      // leaving a third request to start the identical download all over
      // again.
    }).whenComplete(() {
      if (identical(_inFlight[k], job)) _inFlight.remove(k);
    });
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
    String bucket = privateBucket,
    List<int>? keyOverride,
  }) async {
    final raw = await bytes(
        bucket: bucket, path: path, associatedData: associatedData,
        keyOverride: keyOverride,);
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
    String bucket = privateBucket,
    List<int>? keyOverride,
  }) async {
    final raw = await bytes(
        bucket: bucket, path: path, associatedData: associatedData,
        keyOverride: keyOverride,);
    return _provider(bucket, path, raw, null);
  }

  /// The tile provider for [path] if its plaintext is ALREADY in L2, built
  /// synchronously — or null.
  ///
  /// [tileProvider] cannot answer this question without a `Future`, and a
  /// `Future` costs a frame with `_provider == null` even when the answer was
  /// a map lookup away. That frame is the placeholder flashing over a picture
  /// this process is holding in RAM, which is what "it loads again every time
  /// I go back" actually is. Chat's pager removed the same frame the same way,
  /// with `MediaUrls.cached` before `MediaUrls.sign`.
  ///
  /// No associated data and no key: nothing is decrypted here. A hit means the
  /// decrypt already happened under whatever key was current, and the key
  /// epoch is part of [_key], so a rewrap misses rather than mispaints.
  ///
  /// [decodeWidth] must be the SAME expression the async path passes for this
  /// object, or the synchronous answer carries a different `ResizeImageKey`
  /// and buys a second decode of bytes already decoded. Null — the tile case —
  /// is unbounded, which is its own shared key.
  static ImageProvider? warmTileProvider({
    required String path,
    String bucket = privateBucket,
    int? decodeWidth,
  }) {
    final k = _key(bucket, path);
    final hit = _l2.remove(k);
    if (hit == null) return null;
    _l2[k] = hit; // re-insert: most recently used
    return _provider(bucket, path, hit.bytes, decodeWidth);
  }

  /// A provider for the original. [decodeWidth] null mounts it unbounded, which
  /// is what the zoom layer wants and what nothing else should ask for.
  static Future<ImageProvider> fullProvider({
    required String path,
    required String associatedData,
    int? decodeWidth,
    String bucket = privateBucket,
    List<int>? keyOverride,
  }) async {
    final raw = await bytes(
        bucket: bucket, path: path, associatedData: associatedData,
        keyOverride: keyOverride,);
    return _provider(bucket, path, raw, decodeWidth);
  }

  /// Builds — and remembers — the provider over [raw].
  ///
  /// Remembering matters as much as building: `MemoryImage.obtainKey` returns
  /// `this`, so every painted photo is strongly reachable from
  /// `PaintingBinding.instance.imageCache` (1000 entries, under a byte ceiling
  /// [boundImageCache] scales to the phone). Dropping an L2 entry without
  /// evicting its providers frees nothing at all.
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
    // Declared, then assigned: MemoryImage and ResizeImage are ImageProvider
    // over different key types, so a ternary infers Object — and `dart fix`
    // strips an explicit type off an initialised local, which is how this
    // once stopped compiling.
    final ImageProvider provider;
    if (decodeWidth == null) {
      provider = memory;
    } else {
      provider = ResizeImage(memory, width: decodeWidth);
    }
    // contains, not a bare add: MemoryImage compares its bytes by REFERENCE,
    // so every provider built over one L2 entry at one width is EQUAL to the
    // last, and appending on every rebuild grows a list of duplicates that all
    // name the SAME ImageCache entry. One is what eviction needs.
    if (entry != null) {
      if (!entry.providers.contains(provider)) {
        entry.providers.add(provider);
        // And the key it is FILED UNDER, which is not the provider itself for
        // every provider — see [_Plain.cacheKeys]. Synchronous in practice:
        // MemoryImage.obtainKey returns a SynchronousFuture and ResizeImage
        // passes that straight through, so the key is recorded before this
        // method returns.
        provider
            .obtainKey(ImageConfiguration.empty)
            .then(entry.cacheKeys.add);
      }
    } else {
      // No entry owns these bytes. Either a [clear] landed between the admit
      // and the caller resuming, or the load was fenced out by one — and a
      // decoded frame that nothing tracks is a frame no later `clear()` can
      // ever reach, which is a worse leak than the one the fence closes.
      // Remembered here so the next clear takes it.
      provider.obtainKey(ImageConfiguration.empty).then(_orphanKeys.add);
    }
    return provider;
  }

  /// ImageCache keys for providers built over bytes no L2 entry owns.
  ///
  /// Small and bounded in practice — it takes a cover raise landing inside the
  /// microtask between a decrypt finishing and its caller resuming — but
  /// unbounded in principle, so [clear] empties it as well as draining it.
  static final List<Object> _orphanKeys = [];

  static Future<Uint8List> _load(
    String bucket,
    String path,
    String associatedData,
    List<int>? keyOverride,
  ) async {
    final packed = await _cipherBytes(bucket, path);
    return CryptoCore.decryptBytesOffThread(
      packed,
      associatedData: associatedData,
      keyOverride: keyOverride,
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
    // Whatever was there first, properly. A bare overwrite dropped the old
    // entry's byte count and its providers on the floor: `_l2Bytes` then only
    // ever grew, so the ceiling was reached early and permanently, and the
    // decoded frames of the replaced entry stayed resident with nothing left
    // pointing at them to evict. `clear()` emptying `_inFlight` while a load
    // is still running is the ordinary way two admits land on one key.
    _evict(key);
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
    _dropDecodes(gone);
  }

  /// Takes the decoded frames of [entry] out of Flutter's ImageCache.
  ///
  /// By KEY, not by provider, and that distinction is the whole reason this is
  /// a method. `evict` matches on the object a provider's `obtainKey` returns:
  /// `MemoryImage` returns `this`, so passing the provider worked for the
  /// unbounded tiles — but `ResizeImage` returns a `ResizeImageKey`, so
  /// passing the `ResizeImage` matched nothing, returned false, and said
  /// nothing about it. Every bounded decode this class has ever built — every
  /// timeline cover, every zoomed original — therefore survived the clear that
  /// exists to drop it, and only the global `imageCache.clear()` underneath was
  /// really doing the work.
  static void _dropDecodes(_Plain entry) {
    for (final key in entry.cacheKeys) {
      // includeLive defaults to true: a frame still on screen goes too, which
      // is the case that matters behind the cover.
      PaintingBinding.instance.imageCache.evict(key);
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
  /// moment the design claims they are gone. `evict` takes both: its
  /// `includeLive` defaults to true, so the provider goes from the cache AND
  /// from the live-image set in one call.
  ///
  /// **Targeted, not global.** This used to finish with
  /// `imageCache..clear()..clearLiveImages()`, which is every decoded frame in
  /// the PROCESS — chat photographs, gallery tiles, avatars, none of which are
  /// encrypted and all of which sit in plaintext on disk under
  /// `PlainMediaCache` regardless. The cover rises on any focus loss, a glance
  /// at the notification shade included, so that line threw away the whole
  /// app's decode cache several times an hour and bought nothing for the media
  /// it was emptying: the bytes it "protected" were readable at the filesystem
  /// level either way. Re-decoding all of it on the way back in IS the loading
  /// wheel on media the phone already has. The providers this file built are
  /// the ones holding decrypted pixels, and evicting exactly those keeps the
  /// promise this method actually makes.
  ///
  /// Sign-out is a different question and answers it in its own place:
  /// `_endSession` empties every plaintext store and then clears the image
  /// cache globally, which is correct there because the couple is ending.
  ///
  /// L1 is left alone. It is ciphertext, and re-downloading it on every cover
  /// raise would be a great deal of traffic to protect nothing.
  static void clear() {
    for (final e in _l2.values) {
      _dropDecodes(e);
    }
    // The frames that belong to no entry, for the reason [_orphanKeys] gives.
    for (final key in _orphanKeys) {
      PaintingBinding.instance.imageCache.evict(key);
    }
    _orphanKeys.clear();
    _l2.clear();
    _l2Bytes = 0;
    _inFlight.clear();
    // A load already running cannot be cancelled, and its continuation calls
    // _admit — so without this the cover rises, the clear runs, and a decrypt
    // that was in flight puts plaintext BACK into L2 a moment later, behind
    // the cover, which is the one moment the design promises there is none.
    // The generation it started under no longer matches, so the continuation
    // returns the bytes to its own caller and admits nothing.
    _generation++;
  }

  /// Bumped by [clear]. A decrypt that started before it does not get to
  /// populate the cache after it.
  static int _generation = 0;

  /// Ciphertext too — sign-out, not a cover raise.
  static Future<void> clearAll() async {
    clear();
    try {
      await _l1.emptyCache();
    } catch (e) {
      debugPrint('[media] L1 empty failed: ${e.runtimeType}');
    }
  }
}

/// One decrypted object, plus every provider built over it, so eviction can
/// take the ImageCache entries with it.
class _Plain {
  _Plain(this.bytes);
  final Uint8List bytes;

  /// Providers built over [bytes]. The dedup set, not the eviction set.
  final List<ImageProvider> providers = [];

  /// What those providers are FILED UNDER in Flutter's ImageCache, which is a
  /// different object for the bounded ones: `MemoryImage.obtainKey` returns
  /// `this`, `ResizeImage.obtainKey` returns a `ResizeImageKey`. Evicting is
  /// key-matched, so this list — not [providers] — is what `_dropDecodes`
  /// walks.
  final List<Object> cacheKeys = [];
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
