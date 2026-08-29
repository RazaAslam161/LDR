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
/// No key → empty results (the picker shows a friendly "add your key" note
/// instead).
class GiphyService {
  GiphyService._();

  static String _key = '';
  static bool _resolved = false;

  /// False only once a fetch has actually come back without a key.
  ///
  /// giphy_picker.dart:118 reads this synchronously, before the first fetch
  /// can have resolved. Treating "not known yet" as unconfigured flashes the
  /// "add a key" note over the top of every open, and after a failed fetch it
  /// blames the configuration for what is a network problem.
  static bool get isConfigured => !_resolved || _key.isNotEmpty;

  static Future<List<GiphyGif>> trending({int limit = 24}) =>
      _fetch('trending', {'limit': '$limit'});

  static Future<List<GiphyGif>> search(String q, {int limit = 24}) =>
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
      // Offline, signed out, or the function is not deployed. All three are
      // "no GIFs right now", which the picker already renders as an empty grid.
      // Reported as well as printed: silenceLogsInRelease makes debugPrint an
      // empty closure in a shipped build, so this line reaches nobody on a
      // handset — and "the giphy-key function is not answering" is exactly the
      // sort of thing only the field can tell us.
      debugPrint('[giphy] key unavailable: ${e.runtimeType}');
      ErrorReporter.report(e, st, kind: 'giphy');
    }
    return _key;
  }

  static Future<List<GiphyGif>> _fetch(
    String endpoint,
    Map<String, String> params,
  ) async {
    final key = await _ensureKey();
    if (key.isEmpty) return const [];
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
        // rides in the exception TYPE because that is what [ErrorReporter]
        // sends: `detail` is a machine code read from a typed field it already
        // knows, and free text never leaves the device.
        debugPrint('[giphy] $endpoint HTTP ${res.statusCode}');
        ErrorReporter.report(
            _statusFailure(res.statusCode), StackTrace.current, kind: 'giphy',);
        return const [];
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
      return out;
    } catch (e, st) {
      // Timeout, DNS, or a response shape that no longer fits the cast above.
      // Swallowed unlogged, every one of them arrived at the user as "No GIFs
      // found — try another word.", blaming the words they typed — on the
      // trending load they typed none.
      debugPrint('[giphy] $endpoint failed: ${e.runtimeType}');
      ErrorReporter.report(e, st, kind: 'giphy');
      return const [];
    }
  }

  static Exception _statusFailure(int status) => switch (status) {
        401 || 403 => GiphyKeyRejected(),
        429 => GiphyRateLimited(),
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
