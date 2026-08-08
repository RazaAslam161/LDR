import 'package:http/http.dart' as http;

/// An HTTP client that refuses to wait forever.
///
/// The app makes ~94 network calls and only a handful set their own timeout. On
/// a good connection that never shows; on a 3G or captive-portal connection a
/// socket can sit open indefinitely, and the screen that is awaiting it just
/// never finishes — a spinner with no end and no error. Fixing that call site
/// by call site would miss the ones written next week, so the ceiling lives
/// here, under every query, RPC, auth call and function invoke at once.
///
/// This is a backstop, not a UX policy: individual calls may still set a
/// shorter timeout where the user is actively waiting on them.
class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient(
    this._inner, {
    this.timeout = const Duration(seconds: 30),
    this.uploadTimeout = const Duration(minutes: 5),
  });

  final http.Client _inner;

  /// Ceiling for ordinary API traffic — queries, RPCs, auth, edge functions.
  /// Generous enough for a slow network, short enough that a dead connection
  /// surfaces as an error the UI can show instead of an endless wait.
  final Duration timeout;

  /// Storage transfers move whole photos and videos and legitimately take
  /// minutes on a poor connection, so they get their own, much larger ceiling.
  /// Applying the API timeout here would cancel real uploads mid-flight.
  final Duration uploadTimeout;

  bool _isStorage(Uri url) => url.path.contains('/storage/v1/');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final limit = _isStorage(request.url) ? uploadTimeout : timeout;
    return _inner.send(request).timeout(
      limit,
      onTimeout: () => throw http.ClientException(
        'Request timed out after ${limit.inSeconds}s',
        request.url,
      ),
    );
  }

  @override
  void close() => _inner.close();
}
