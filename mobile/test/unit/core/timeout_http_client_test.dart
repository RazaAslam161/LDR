import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/net/timeout_http_client.dart';

/// A client that never answers — a stalled socket on a bad connection.
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// Records which URL it was asked for, then answers immediately.
class _RecordingClient extends http.BaseClient {
  Uri? lastUrl;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastUrl = request.url;
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

void main() {
  group('TimeoutHttpClient', () {
    test('a stalled API request fails instead of hanging forever', () async {
      final client = TimeoutHttpClient(
        _HangingClient(),
        timeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        client.send(http.Request('GET', Uri.parse('https://x.co/rest/v1/f'))),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('storage transfers get the long ceiling, not the API one', () async {
      // Uploads legitimately take minutes on a poor connection. If they shared
      // the API timeout, real photo and video uploads would be cancelled
      // mid-flight — a worse bug than the one this class fixes.
      final client = TimeoutHttpClient(
        _HangingClient(),
        timeout: const Duration(milliseconds: 50),
        uploadTimeout: const Duration(seconds: 30),
      );

      var timedOut = false;
      unawaited(client
          .send(http.Request(
              'POST', Uri.parse('https://x.co/storage/v1/object/media/a.jpg'),),)
          .catchError((_) {
        timedOut = true;
        return http.StreamedResponse(const Stream.empty(), 500);
      }),);

      // Well past the API timeout; the upload must still be in flight.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(timedOut, isFalse,
          reason: 'an upload was cancelled by the short API timeout',);
    });

    test('requests pass through untouched when they answer', () async {
      final inner = _RecordingClient();
      final client = TimeoutHttpClient(inner);
      final url = Uri.parse('https://x.co/rest/v1/profiles');

      final res = await client.send(http.Request('GET', url));

      expect(res.statusCode, 200);
      expect(inner.lastUrl, url);
    });
  });
}
