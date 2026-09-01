import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:miles/core/media/encrypted_media_cache.dart' show EncryptedMediaCache;

/// Serves one decrypted video to the platform player over loopback, from RAM.
///
/// video_player cannot be handed bytes — it wants a file or a URL. The obvious
/// route is to decrypt to `getTemporaryDirectory()` and delete on dispose, and
/// that is exactly what [EncryptedMediaCache]'s header calls out as the thing
/// this app does not do: backgrounding is when Android kills the process, so
/// `dispose` frequently never runs, and the plaintext outlives the session on
/// disk. For a PIN-gated vault that is the wrong trade.
///
/// So the bytes stay in memory and the player fetches them from 127.0.0.1.
/// Nothing is written to storage, and when this object is closed the video is
/// unreachable — there is no file left to find.
///
/// Bound to the loopback interface only, so nothing off-device can reach it,
/// and behind a 32-byte random path so another app on the handset cannot guess
/// the URL while the server is briefly up.
class VaultVideoServer {
  VaultVideoServer._(this._server, this._token, this._bytes, this._mime);

  final HttpServer _server;
  final String _token;
  final Uint8List _bytes;
  final String _mime;

  /// Feed this to VideoPlayerController.networkUrl.
  Uri get url =>
      Uri.parse('http://127.0.0.1:${_server.port}/$_token');

  static Future<VaultVideoServer> start({
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final token = _randomToken();
    final s = VaultVideoServer._(server, token, bytes, mimeType);
    unawaited(s._listen());
    return s;
  }

  Future<void> _listen() async {
    await for (final req in _server) {
      try {
        if (req.uri.path != '/$_token') {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          continue;
        }
        await _serve(req);
      } catch (e) {
        debugPrint('[vault-video] request failed: ${e.runtimeType}');
      }
    }
  }

  /// Range support is not optional: without it the player cannot seek, and some
  /// platform decoders refuse to start at all when a stream is not seekable.
  Future<void> _serve(HttpRequest req) async {
    final total = _bytes.length;
    final res = req.response
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.contentType = ContentType.parse(_mime);

    final range = req.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = total - 1;

    if (range != null && range.startsWith('bytes=')) {
      final spec = range.substring(6).split('-');
      final rawStart = int.tryParse(spec.first);
      final rawEnd = spec.length > 1 ? int.tryParse(spec[1]) : null;
      if (rawStart == null && rawEnd != null) {
        // `bytes=-N` means the LAST n bytes, not "from zero to n".
        start = total - rawEnd;
        if (start < 0) start = 0;
      } else {
        start = rawStart ?? 0;
        if (rawEnd != null) end = rawEnd;
      }
      if (start >= total) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }
      if (end >= total) end = total - 1;
      res
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total',);
    } else {
      res.statusCode = HttpStatus.ok;
    }

    final length = end - start + 1;
    res.headers.contentLength = length;
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }
    res.add(Uint8List.sublistView(_bytes, start, end + 1));
    await res.close();
  }

  /// Closes the socket. After this the video exists nowhere but this object's
  /// own byte list, which goes with it.
  Future<void> close() async {
    try {
      await _server.close(force: true);
    } catch (e) {
      debugPrint('[vault-video] close failed: ${e.runtimeType}');
    }
  }

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
