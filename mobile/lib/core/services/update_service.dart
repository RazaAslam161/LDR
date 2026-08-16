import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/main.dart';
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

  /// Static, like the transfer it belongs to. As an instance field, Cancel was
  /// tapped on a FRESH UpdateService created by the reopened sheet, whose
  /// `_client` was null — so it silently cancelled nothing while the real
  /// download carried on.
  static http.Client? _client;

  /// The download in flight, and its progress, held STATICALLY.
  ///
  /// These used to live in the update sheet's State, which owns nothing that
  /// can survive: leaving the app raises the disguise cover, and that swaps the
  /// whole widget tree, so the sheet was disposed and its `dispose()` cancelled
  /// the transfer. Glancing at another app 200 MB into a 219 MB download threw
  /// all of it away, and coming back showed no sheet and no explanation.
  ///
  /// The cover still rises — that is a security property and not negotiable.
  /// What changed is who owns the download: the service does, so the widget is
  /// free to come and go over the top of it. Reopening the sheet re-attaches to
  /// whatever is already running instead of starting a second one.
  static Future<File>? _inFlight;

  /// 0..1 while downloading. Listened to by the sheet, so progress keeps
  /// advancing across a background and is correct the instant it reopens.
  static final ValueNotifier<double> progress = ValueNotifier(0);

  /// A finished, hash-verified APK waiting to be installed. Kept so backing out
  /// of the system installer and returning does not re-fetch 219 MB.
  static File? ready;

  /// Whether a transfer is running right now.
  static bool get isDownloading => _inFlight != null;

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
  ///
  /// Flagged as a deliberate overlay first. Leaving for Settings reports
  /// `paused` exactly like a real backgrounding, so the cover went up, the
  /// widget tree was swapped, and the update sheet the user was standing in was
  /// destroyed — they granted the permission, came back to no sheet, and had to
  /// force-stop the app for the offer to reappear. That is the one flow a user
  /// cannot skip on the way to installing an update.
  ///
  /// Unlike the pickers, there is no result to await, so this cannot clear the
  /// flag in a `finally`; [MilesApp] clears it on resume instead.
  Future<void> openInstallSettings() {
    MilesApp.systemOverlayActive = true;
    return _channel.invokeMethod<void>('openInstallSettings');
  }

  /// Joins the transfer already running, or starts one.
  ///
  /// Idempotent on purpose: the sheet calls this on every open, and a second
  /// call while bytes are moving must never open a second socket onto the same
  /// file. A caller that arrives mid-download simply awaits the same future and
  /// watches [progress].
  Future<File> start() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final run = download((received, total) {
      progress.value = total > 0 ? received / total : 0;
    });
    _inFlight = run;
    // Cleared however it ends — success, failure or cancel — so a later attempt
    // is never blocked by a future that already completed.
    unawaited(
      run.then(
        (f) => ready = f,
        onError: (_) => ready = null,
      ).whenComplete(() {
        _inFlight = null;
      }),
    );
    return run;
  }

  /// Streams the published APK to the cache and verifies its SHA-256 as it goes,
  /// so a ~220 MB file never sits in memory and a corrupt or tampered download
  /// is rejected before it can be handed to the installer.
  ///
  /// [onProgress] reports received/total bytes; total is -1 while unknown.
  /// Throws on a network error, an HTTP error, or a hash mismatch. Cancelling
  /// closes the socket, which surfaces here as a thrown error the caller treats
  /// as a cancel.
  ///
  /// Prefer [start]: it is what keeps a single transfer alive across the sheet
  /// being disposed, and this takes a callback that only the sheet used to own.
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
