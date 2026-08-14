import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/features/closer/private_vault/private_vault_repository.dart';
import 'package:path_provider/path_provider.dart';

/// Deduplicates preview/full-media work across a grid and a pager. This avoids
/// concurrent decrypts and downloads for the same item, which previously left
/// several tiles spinning while the device did duplicate work.
class VaultMediaCache {
  VaultMediaCache._();

  static final _previewLoads = <String, Future<File>>{};
  static final _originalLoads = <String, Future<File>>{};
  static final _files = <String, File>{};
  static final _sessionId = _randomId();

  /// The epoch these decrypted files were produced under.
  ///
  /// The cache used to key on a per-PROCESS random id, which is stable across
  /// exactly the event it needed to notice: [CryptoCore.adoptPrivateSeed]
  /// clears only the shared key, so after an escrow restore mid-session this
  /// cache went on serving files decrypted under the key that had just been
  /// replaced — healthy-looking plaintext from a key that no longer exists.
  static int _epoch = CryptoCore.keyEpoch.value;

  static bool _wired = false;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    CryptoCore.keyEpoch.addListener(_onEpochChanged);
  }

  static void _onEpochChanged() {
    if (_epoch == CryptoCore.keyEpoch.value) return;
    _epoch = CryptoCore.keyEpoch.value;
    unawaited(clear());
  }

  static Future<File> getDecryptedFile(VaultItem item) {
    _wire();
    return _previewLoads.putIfAbsent(
      item.id,
      () => _decryptPreview(item).catchError((Object error, StackTrace stack) {
        _previewLoads.remove(item.id);
        Error.throwWithStackTrace(error, stack);
      }),
    );
  }

  static Future<File> getDecryptedOriginal(VaultItem item) {
    if (!item.hasOriginalMedia) return getDecryptedFile(item);
    return _originalLoads.putIfAbsent(
      item.id,
      () => _downloadAndDecryptOriginal(item)
          .catchError((Object error, StackTrace stack) {
        _originalLoads.remove(item.id);
        Error.throwWithStackTrace(error, stack);
      }),
    );
  }

  static void prefetchOriginal(VaultItem item) {
    if (!item.hasOriginalMedia) return;
    getDecryptedOriginal(item).catchError((_) => File(''));
  }

  static Future<File> _decryptPreview(VaultItem item) async {
    final bytes = await _decrypt(item.payload, item.ad);
    return _write(item, bytes, role: 'preview');
  }

  static Future<File> _downloadAndDecryptOriginal(VaultItem item) async {
    Uint8List encrypted;
    try {
      encrypted = await SupabaseService.client.storage
          .from('couple_intimate')
          .download(item.resolvedStoragePath)
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      // Items written by the failed first implementation used this path. Keep
      // them readable where the original upload did make it to storage.
      if (item.storagePath != null) rethrow;
      encrypted = await SupabaseService.client.storage
          .from('couple_intimate')
          .download('vault/${item.ad}.enc')
          .timeout(const Duration(minutes: 2));
    }
    // The packed bytes go STRAIGHT to the isolate.
    //
    // This previously ran `unpackFull` first and shipped an EncryptedPayload,
    // whose three fields are base64 STRINGS — so a 4 MB original was
    // base64-encoded to build the request and decoded again inside it: +33 %
    // allocation and two extra full passes over the bytes, per view, to move
    // data that was already in exactly the shape the cipher wanted.
    return _write(
      item,
      await CryptoCore.decryptBytesOffThread(encrypted,
          associatedData: item.ad,),
      role: 'original',
    );
  }

  /// The inline preview column. Small enough that an isolate hop costs more
  /// than the work — `compute` spawns a fresh isolate per call, tens of
  /// milliseconds on an IN2015, while XChaCha20 over a resized preview is well
  /// under one.
  static Future<Uint8List> _decrypt(
    EncryptedPayload payload,
    String ad,
  ) =>
      CryptoCore.decryptBytes(payload, associatedData: ad);

  static Future<File> _write(
    VaultItem item,
    Uint8List bytes, {
    required String role,
  }) async {
    final directory = await getTemporaryDirectory();
    final extension = _extensionFor(item);
    // The epoch is in the filename, so a file written under a replaced key can
    // never be mistaken for a current one even if the delete below fails.
    final file = File(
        '${directory.path}/vault_${_sessionId}_${_epoch}_${role}_${item.id}.$extension');
    await file.writeAsBytes(bytes, flush: true);
    _files[file.path] = file;
    return file;
  }

  static String _extensionFor(VaultItem item) {
    switch (item.mediaMimeType) {
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
      case 'image/gif':
        return 'gif';
      case 'video/quicktime':
        return 'mov';
      case 'video/webm':
        return 'webm';
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/aac':
        return 'aac';
      case 'audio/mp4':
        return 'm4a';
      default:
        return switch (item.kind) {
          VaultKind.photo => 'jpg',
          VaultKind.video => 'mp4',
          VaultKind.voice => 'm4a',
          _ => 'bin',
        };
    }
  }

  static Future<void> clear() async {
    final files = _files.values.toList(growable: false);
    _previewLoads.clear();
    _originalLoads.clear();
    _files.clear();
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // The OS owns its temp directory. A later cleanup can remove a file
        // that another platform component has temporarily locked.
      }
    }
  }

  static String _randomId() {
    final random = Random.secure();
    final bytes = List<int>.generate(9, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
