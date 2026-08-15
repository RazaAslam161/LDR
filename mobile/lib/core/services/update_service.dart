import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:path_provider/path_provider.dart';

/// In-app self-update for the sideloaded build.
///
/// There is no store, so a new build reaches a phone only by being sideloaded —
/// which until now meant rebuilding and hand-transferring to every device on
/// every change. Instead the server publishes the latest APK's URL, build
/// number and SHA-256 in `app_release` (read once at startup by [ReleaseGate]),
/// and an out-of-date client downloads and installs it over itself.
///
/// Two hard constraints:
///  * **Sideload only.** A Play build that downloads and installs its own APK is
///    a Device and Network Abuse strike, so everything here is gated on
///    [DisguiseService.enabled] — false on the play channel — and the install
///    permission and FileProvider live in `src/sideload/` alone.
///  * **Same signing key.** Android refuses to update in place across a
///    signature change; a mismatched APK installs as a new app and the old one's
///    secure-storage keys are lost. The server's APK must be signed with the key
///    the installed build already carries. The SHA-256 check here guards
///    corruption and tampering in transit, not the signature — the OS does that.
class UpdateService {
  static const _channel = MethodChannel('miles/updater');

  /// Whether this channel may install its own APK at all. Read once at startup
  /// from the sideload/play BuildConfig.
  ///
  /// Defaults to false so a channel that cannot answer never offers a download.
  /// This used to piggyback on [DisguiseService.enabled], which was a mistake:
  /// that flag describes what the launcher shows, and when the play channel
  /// started shipping the covers as an opt-in it became true there too — which
  /// would have put a self-update prompt inside a Play build.
  static bool allowed = false;

  static Future<void> loadAllowed() async {
    try {
      allowed = await _channel
              .invokeMethod<bool>('isAllowed')
              .timeout(const Duration(seconds: 2)) ??
          false;
    } catch (_) {
      // Non-Android host, or the query failed — stay off.
    }
  }

  /// A newer build exists, we know where to get it, and this channel is allowed
  /// to self-update. False on the play build and when no APK has been published.
  static bool get available =>
      allowed &&
      (ReleaseGate.apkUrl?.isNotEmpty ?? false) &&
      ReleaseGate.latestBuild > ReleaseGate.buildNumber;

  http.Client? _client;

  /// Whether the OS will let this app install packages. On API < 26 it always
  /// can; from 26 the user must grant "install unknown apps" for this source.
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Sends the user to the system screen that grants install permission. They
  /// return and try again — there is no callback for the grant.
  Future<void> openInstallSettings() =>
      _channel.invokeMethod<void>('openInstallSettings');

  /// Streams the published APK to the cache and verifies its SHA-256 as it goes,
  /// so a ~220 MB file never sits in memory and a corrupt or tampered download
  /// is rejected before it can be handed to the installer.
  ///
  /// [onProgress] reports received/total bytes; total is -1 while unknown.
  /// Throws on a network error, an HTTP error, or a hash mismatch. Cancelling
  /// closes the socket, which surfaces here as a thrown error the caller treats
  /// as a cancel.
  Future<File> download(void Function(int received, int total) onProgress) async {
    final url = ReleaseGate.apkUrl;
    if (url == null || url.isEmpty) {
      throw StateError('no update url');
    }

    final dir = await getTemporaryDirectory();
    await _clearStale(dir);
    final file = File('${dir.path}/update_${ReleaseGate.latestBuild}.apk');

    final client = http.Client();
    _client = client;
    IOSink? sink;
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('update download failed: ${response.statusCode}');
      }
      final total = response.contentLength ?? -1;
      sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      hasher.close();

      final expected = ReleaseGate.apkSha256?.toLowerCase();
      final actual = digestSink.value.toString();
      if (expected != null && expected.isNotEmpty && actual != expected) {
        await file.delete();
        throw const _IntegrityException();
      }
      return file;
    } catch (_) {
      // close() can itself throw (a disk-full surfaces here); swallow it so it
      // does not mask the real error or skip the partial-file cleanup below.
      try {
        await sink?.close();
      } catch (_) {}
      if (file.existsSync()) {
        try {
          await file.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      _client = null;
      client.close();
    }
  }

  /// Aborts an in-flight [download].
  void cancel() {
    _client?.close();
    _client = null;
  }

  /// Hands the downloaded APK to the system installer. The OS then shows its own
  /// confirmation and replaces this app; nothing runs here afterward.
  Future<void> install(File apk) =>
      _channel.invokeMethod<void>('install', {'path': apk.path});

  /// Removes any half-finished or superseded download so the cache does not
  /// accumulate 220 MB files across releases.
  Future<void> _clearStale(Directory dir) async {
    try {
      for (final entry in dir.listSync()) {
        final name = entry.uri.pathSegments.last;
        if (entry is File && name.startsWith('update_') && name.endsWith('.apk')) {
          await entry.delete();
        }
      }
    } catch (e) {
      debugPrint('[update] could not clear stale apks: ${e.runtimeType}');
    }
  }
}

/// Thrown when the download's hash does not match the published SHA-256.
class _IntegrityException implements Exception {
  const _IntegrityException();
  @override
  String toString() => 'the download did not match its checksum';
}

/// Collects the single [Digest] that [Hash.startChunkedConversion] emits on
/// close, so hashing can run chunk-by-chunk alongside the file write instead of
/// over the whole file in memory. Avoids a dependency on package:convert's
/// AccumulatorSink for one line.
class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
