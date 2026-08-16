import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/vault/vault_video_server.dart';

/// Vault video is encrypted at rest and video_player cannot be handed bytes,
/// so the decrypted stream is served from RAM over loopback rather than written
/// to a temp file that outlives a process kill. Seeking depends entirely on
/// Range being right, and a decoder that cannot seek often refuses to start at
/// all — so the range arithmetic is pinned here.
void main() {
  final body = Uint8List.fromList(List.generate(1000, (i) => i % 256));
  late VaultVideoServer server;
  late HttpClient client;

  setUp(() async {
    server = await VaultVideoServer.start(bytes: body, mimeType: 'video/mp4');
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  Future<HttpClientResponse> get({String? range, String method = 'GET'}) async {
    final req = await client.openUrl(method, server.url);
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    return req.close();
  }

  test('serves the whole body when no range is asked for', () async {
    final res = await get();
    expect(res.statusCode, HttpStatus.ok);
    expect(res.contentLength, 1000);
    expect(res.headers.value(HttpHeaders.acceptRangesHeader), 'bytes');
  });

  test('a bounded range returns exactly that slice as 206', () async {
    final res = await get(range: 'bytes=100-199');
    expect(res.statusCode, HttpStatus.partialContent);
    expect(res.contentLength, 100);
    expect(res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 100-199/1000');
  });

  test('an open-ended range runs to the last byte', () async {
    final res = await get(range: 'bytes=900-');
    expect(res.statusCode, HttpStatus.partialContent);
    expect(res.contentLength, 100);
    expect(res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 900-999/1000');
  });

  test('a suffix range means the LAST n bytes, not the first n', () async {
    // bytes=-50 is the tail. Reading it as 0..50 hands the decoder the wrong
    // part of the file, which for an mp4 moov atom means it never starts.
    final res = await get(range: 'bytes=-50');
    expect(res.statusCode, HttpStatus.partialContent);
    expect(res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 950-999/1000');
  });

  test('a range past the end is refused, not clamped silently', () async {
    final res = await get(range: 'bytes=5000-6000');
    expect(res.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes */1000');
  });

  test('an end past the last byte is clamped to the last byte', () async {
    final res = await get(range: 'bytes=990-99999');
    expect(res.statusCode, HttpStatus.partialContent);
    expect(res.contentLength, 10);
  });

  test('the bytes served are the bytes given', () async {
    final res = await get(range: 'bytes=10-19');
    final got = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(got, body.sublist(10, 20));
  });

  test('HEAD reports length without a body', () async {
    final res = await get(method: 'HEAD');
    expect(res.contentLength, 1000);
    final got = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(got, isEmpty);
  });

  test('a wrong path is refused — the token is the only way in', () async {
    final wrong = Uri.parse('http://127.0.0.1:${server.url.port}/nope');
    final res = await (await client.getUrl(wrong)).close();
    expect(res.statusCode, HttpStatus.notFound);
  });

  test('after close the video is unreachable', () async {
    await server.close();
    // The exact exception type is platform-dependent; that it cannot connect
    // at all is the property that matters.
    await expectLater(get(), throwsA(isA<Exception>()));
  });
}
