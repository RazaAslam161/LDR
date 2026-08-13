import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/private_vault/private_vault_repository.dart';
import 'package:path_provider/path_provider.dart';

class DecryptRequest {
  const DecryptRequest(this.payload, this.ad, this.keyBytes);

  final EncryptedPayload payload;
  final String? ad;
  final List<int>? keyBytes;
}

Future<Uint8List> _isolateDecrypt(DecryptRequest request) async {
  final nonce = base64Decode(request.payload.nonceB64);
  final mac = base64Decode(request.payload.macB64);
  final ciphertext = base64Decode(request.payload.ciphertextB64);

  if (nonce.every((byte) => byte == 0) && mac.every((byte) => byte == 0)) {
    return Uint8List.fromList(ciphertext);
  }
  if (request.keyBytes == null) {
    throw StateError('The shared vault key is unavailable.');
  }

  final clear = await Xchacha20.poly1305Aead().decrypt(
    SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
    secretKey: SecretKey(request.keyBytes!),
    aad: request.ad == null ? const <int>[] : utf8.encode(request.ad!),
  );
  return Uint8List.fromList(clear);
}

/// Deduplicates preview/full-media work across a grid and a pager. This avoids
/// concurrent decrypts and downloads for the same item, which previously left
/// several tiles spinning while the device did duplicate work.
class VaultMediaCache {
  VaultMediaCache._();

  static final _previewLoads = <String, Future<File>>{};
  static final _originalLoads = <String, Future<File>>{};
  static final _files = <String, File>{};
  static final _sessionId = _randomId();

  static Future<File> getDecryptedFile(VaultItem item) {
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
    return _write(item, await _decrypt(unpackFull(encrypted), item.ad),
        role: 'original');
  }

  static Future<Uint8List> _decrypt(
    EncryptedPayload payload,
    String ad,
  ) async {
    final keyBytes = await CryptoCore.exportSharedKeyBytes();
    return compute(_isolateDecrypt, DecryptRequest(payload, ad, keyBytes));
  }

  static Future<File> _write(
    VaultItem item,
    Uint8List bytes, {
    required String role,
  }) async {
    final directory = await getTemporaryDirectory();
    final extension = _extensionFor(item);
    final file = File(
        '${directory.path}/vault_${_sessionId}_${role}_${item.id}.$extension');
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
