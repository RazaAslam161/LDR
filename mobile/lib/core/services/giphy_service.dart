import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/utils/json_utils.dart';

/// One GIF result from GIPHY.
class GiphyGif {
  const GiphyGif({
    required this.id,
    required this.previewUrl,
    required this.fullUrl,
  });
  final String id;
  final String previewUrl; // small, for the grid
  final String fullUrl; // sent / flung
}

/// How a fetch ended.
///
/// A bare `List<GiphyGif>` was the whole answer, so a revoked key, a spent
/// quota, a GIPHY outage and a handset with no network all reached the picker
/// as the same empty list a search that genuinely matched nothing returns —
/// and the picker, having nothing to branch on, told the user their word was
/// the problem. That is the one explanation that is never true of a fetch that
/// never left the phone.
enum GiphyStatus {
  /// GIPHY answered. [GiphyResult.gifs] may still be empty, and THAT one is
  /// the only case that really is "nothing matched".
  ok,

  /// The key lookup answered and there is no key. No amount of retrying moves
  /// this; a row in `app_secrets` does.
  notConfigured,

  /// GIPHY refused the key itself — revoked, or belonging to a deleted app.
  /// Separate from [notConfigured] because a key IS configured, and separate
  /// from [unavailable] because waiting changes nothing: the row has to be
  /// replaced. [GiphyService] drops its cached key on this one so the retry
  /// re-reads `app_secrets` instead of re-sending the key that was just
  /// refused.
  keyRejected,

  /// The key's quota or rate window is spent — possibly by somebody else, on a
  /// key this app cannot see the usage of. Time fixes it and nothing else
  /// does, which is the opposite advice from every other failure here.
  rateLimited,

  /// Nothing was reached — the key function, GIPHY itself, or the network in
  /// between. Retrying is the right response, so the picker offers one.
  unavailable,
}

/// A fetch's outcome: what happened, and what came back if anything did.
class GiphyResult {
  const GiphyResult(this.status, {this.gifs = const []});

  final GiphyStatus status;
  final List<GiphyGif> gifs;
}

/// Thin GIPHY REST client.
///
/// The key comes from the `giphy-key` edge function (`app_secrets` row
/// `GIPHY_API_KEY`), the same route as the Mapbox token — see
/// `core/media/map_token.dart`. It used to be read from `.env`, which pubspec
/// ships as a Flutter asset: it landed in the APK as
/// `assets/flutter_assets/.env` and came back out of a sideloaded build with
/// `unzip`, in plaintext. A GIPHY key is not a cryptographic secret, but it is
/// quota-bound and revocable on an account with no way to notice a stranger
/// spending it, and this app has no update channel — held server-side it
/// rotates in one UPDATE instead of one release to every handset.
///
/// Every way that can go wrong reaches the picker as its own [GiphyStatus] —
/// no key, a key GIPHY refused, a spent quota, nothing reachable — rather than
/// as an empty search, because the fixes are a new `app_secrets` row, waiting,
/// and tapping again, and telling a user to retype their word covers none of
/// them.
class GiphyService {
  GiphyService._();

  static String _key = '';
  static bool _resolved = false;

  static Future<GiphyResult> trending({int limit = 24}) =>
      _fetch('trending', {'limit': '$limit'});

  static Future<GiphyResult> search(String q, {int limit = 24}) =>
      _fetch('search', {'q': q, 'limit': '$limit'});

  /// Fetch the key once per app run. Only an answer latches: a picker opened
  /// while offline retries on the next open rather than claiming for the rest
  /// of the session that no key is configured.
  static Future<String> _ensureKey() async {
    if (_resolved) return _key;
    try {
      final res = await SupabaseService.client.functions.invoke('giphy-key');
      final map = JsonUtils.asMap(res.data);
      _key = JsonUtils.parseString(map['key']).trim();
      _resolved = true;
    } catch (e, st) {
      // Offline, signed out, or the function is not deployed. _resolved stays
      // false through all three, so the fetch reports them as unavailable and
      // the picker offers a retry — never as a key nobody configured.
      // Reported as well as printed: silenceLogsInRelease makes debugPrint an
      // empty closure in a shipped build, so this line reaches nobody on a
      // handset — and "the giphy-key function is not answering" is exactly the
      // sort of thing only the field can tell us.
      debugPrint('[giphy] key unavailable: ${e.runtimeType}');
      ErrorReporter.report(e, st, kind: 'giphy');
    }
    return _key;
  }

  static Future<GiphyResult> _fetch(
    String endpoint,
    Map<String, String> params,
  ) async {
    final key = await _ensureKey();
    if (key.isEmpty) {
      // _resolved is the whole difference between the two, and it is why the
      // picker cannot work this out for itself: the function ANSWERED and the
      // `app_secrets` row is missing (nothing on this handset fixes that), vs
      // the lookup never got an answer at all — offline, signed out, function
      // not deployed — where trying again is exactly right.
      return GiphyResult(
        _resolved ? GiphyStatus.notConfigured : GiphyStatus.unavailable,
      );
    }
    final url = Uri.https('api.giphy.com', '/v1/gifs/$endpoint', {
      ...params,
      'api_key': key,
      // Was 'r' — the most permissive rating Giphy offers below X, on
      // third-party content this app has no control over and every user can
      // surface with one tap. Nothing here is moderated by us, so the ceiling
      // has to come from the source.
      'rating': 'pg-13',
      'bundle': 'messaging_non_clips',
    });
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        // The status used to be dropped on the floor, which made a revoked key
        // and a spent quota — the two failures this file's own doc comment
        // worries about, and the two with completely different fixes —
        // indistinguishable from a search that genuinely matched nothing. It
        // still rides in the exception TYPE for [ErrorReporter], whose `detail`
        // is a machine code read from a typed field it already knows and never
        // free text; it now ALSO reaches the picker, which is the surface the
        // person holding the phone is actually reading.
        final status = _statusFor(res.statusCode);
        if (status == GiphyStatus.keyRejected) {
          // The latch below is per app run, so without this the retry re-sends
          // the key GIPHY just refused and fails identically for as long as the
          // process lives — a button known in advance to do nothing. Dropped,
          // Try again re-reads `app_secrets`, so rotating that row is enough
          // and nobody has to kill the app to pick the new key up.
          _resolved = false;
          _key = '';
        }
        debugPrint('[giphy] $endpoint HTTP ${res.statusCode}');
        ErrorReporter.report(
            _failureFor(status), StackTrace.current, kind: 'giphy',);
        return GiphyResult(status);
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (data['data'] as List?) ?? const [];
      final out = <GiphyGif>[];
      for (final e in list) {
        final images = (e as Map)['images'] as Map?;
        if (images == null) continue;
        final preview = (images['fixed_width_small'] ??
            images['fixed_width'] ??
            images['downsized']) as Map?;
        final full = (images['downsized_medium'] ??
            images['downsized'] ??
            images['fixed_width'] ??
            images['original']) as Map?;
        final pUrl = preview?['url']?.toString();
        final fUrl = full?['url']?.toString();
        if (pUrl == null || fUrl == null) continue;
        out.add(
            GiphyGif(id: e['id'].toString(), previewUrl: pUrl, fullUrl: fUrl),);
      }
      return GiphyResult(GiphyStatus.ok, gifs: out);
    } catch (e, st) {
      // Timeout, DNS, or a response shape that no longer fits the cast above.
      // Swallowed unlogged, every one of them arrived at the user as "No GIFs
      // found — try another word.", blaming the words they typed — on the
      // trending load they typed none. Logging fixed that for the operator;
      // the status is what fixes it for the person holding the phone.
      debugPrint('[giphy] $endpoint failed: ${e.runtimeType}');
      ErrorReporter.report(e, st, kind: 'giphy');
      return const GiphyResult(GiphyStatus.unavailable);
    }
  }

  /// The single place an HTTP code is read as a failure CLASS. What the user
  /// is told and what the reporter is sent both derive from this, so the two
  /// cannot drift into disagreeing about the same response.
  static GiphyStatus _statusFor(int code) => switch (code) {
        401 || 403 => GiphyStatus.keyRejected,
        429 => GiphyStatus.rateLimited,
        _ => GiphyStatus.unavailable,
      };

  static Exception _failureFor(GiphyStatus status) => switch (status) {
        GiphyStatus.keyRejected => GiphyKeyRejected(),
        GiphyStatus.rateLimited => GiphyRateLimited(),
        _ => GiphyBadStatus(),
      };
}

/// GIPHY refused the key — revoked, or deleted with the app it belonged to.
/// The fix is a new key in `app_secrets`, and no other failure here has it.
class GiphyKeyRejected implements Exception {}

/// The key's quota or rate limit is spent — including by somebody else, which
/// is the case this service is otherwise blind to.
class GiphyRateLimited implements Exception {}

/// Any other non-200: a GIPHY outage, or a proxy in front of the handset.
class GiphyBadStatus implements Exception {}
