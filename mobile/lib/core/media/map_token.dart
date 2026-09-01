import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';

/// The Mapbox public token, fetched at runtime rather than compiled in.
///
/// Same reasoning as the TURN credentials: this APK is sideloaded, and anyone
/// can unzip it and run `strings` over the binary. A Mapbox public token is not
/// a secret in the cryptographic sense — it rides in every tile request and
/// Mapbox expects that — but it IS billable against an account that has no way
/// to notice someone else spending it. Held server-side it can be rotated with
/// one UPDATE, which matters for a fleet with no update channel.
///
/// Absent is a first-class state, not a failure. The map screen says it has not
/// been set up yet and shows how, rather than rendering a grey rectangle and
/// leaving the user to guess.
class MapToken {
  MapToken._();

  static String? _token;
  static bool _fetched = false;

  /// True once a fetch has happened, whatever it returned.
  static bool get resolved => _fetched;

  /// Null until [ensure] has run, and null afterwards if none is configured.
  static String? get value => _token;

  static bool get configured => _token?.isNotEmpty ?? false;

  /// Fetch once per app run — once per SUCCESSFUL fetch. Cheap to call
  /// repeatedly.
  static Future<String?> ensure() async {
    if (_fetched) return _token;
    try {
      final res = await SupabaseService.client.functions.invoke('map-token');
      final map = JsonUtils.asMap(res.data);
      final t = JsonUtils.parseStringOrNull(map['token']);
      _token = (t?.isEmpty ?? true) ? null : t;
      // Only a fetch that ANSWERED pins the state. The server saying "not
      // configured" is an answer; a dead socket is not — setting _fetched on
      // the failure path pinned "the world map is not set up yet" for the
      // whole process over one bad moment of connectivity.
      _fetched = true;
    } catch (e) {
      debugPrint('[map] token unavailable: ${e.runtimeType}');
      _token = null;
    }
    return _token;
  }

  /// Forget it, so the next account on this handset does not inherit it.
  ///
  /// It is not sensitive between the two partners, but the sign-out path in
  /// this app clears every other cached credential and leaving one behind is
  /// how the FCM token became somebody else's.
  static void clear() {
    _token = null;
    _fetched = false;
  }
}
