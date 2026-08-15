import 'package:flutter/foundation.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/features/legal/terms_text.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Whether this account has agreed to the current terms.
///
/// Enforced in exactly one place — the router's redirect. There are around
/// thirty-five screens that can put content into this app and adding a check to
/// each of them is how thirty-four of them end up without one.
class TermsGate {
  TermsGate._();

  /// Drives the router's `refreshListenable`, the same way `CryptoCore.keyless`
  /// does. Without it, accepting writes a row and the user keeps looking at the
  /// terms, because nothing told GoRouter to re-run the redirect.
  static final ValueNotifier<bool> accepted = ValueNotifier<bool>(false);

  static int? _version;

  /// The highest terms version this account is on record as having accepted,
  /// or null when that is unknown. Unknown is not the same as zero, but the
  /// gate treats them the same way — see [needsAcceptance].
  static int? get acceptedVersion => _version;

  /// FAILS CLOSED. Null — the value [load] leaves behind when it cannot find
  /// out — gates. A gate that opens because its own check broke is not a gate,
  /// and this one stands in front of every upload path in the app.
  static bool get needsAcceptance =>
      _version == null || _version! < milesTermsVersion;

  /// The server read, injectable so the fail-closed path can be tested without
  /// a database. Returns the highest version on record, or null for none.
  @visibleForTesting
  static Future<int?> Function() fetchAcceptedVersion = _fetchAcceptedVersion;

  /// The server write, injectable for the same reason.
  @visibleForTesting
  static Future<void> Function(int version) recordAcceptance = _recordAcceptance;

  /// Which account the local marker is scoped to. A seam for the same reason
  /// as the two above: reading it goes through `SupabaseService.client`, which
  /// is a `late final` and throws anywhere the app has not booted.
  @visibleForTesting
  static String? Function() currentAccount = () => SupabaseService.currentUserId;

  /// Read the acceptance for whoever is signed in now.
  ///
  /// Called at startup and again from `loadProfile`, so switching accounts on
  /// one handset re-gates rather than inheriting the previous user's answer.
  ///
  /// Everything is inside the try, including the account lookup. A throw before
  /// it would leave [_version] at whatever the last call decided, and on a
  /// fresh process that is null — which gates. Nothing here can open the door
  /// by failing.
  static Future<void> load() async {
    try {
      final uid = currentAccount();
      // The device answers first, so that a server read which times out ten
      // seconds later still leaves a returning user with an answer instead of
      // a locked door. With no local record it leaves null, which is closed.
      final local = await _readLocal(uid);
      _version = local;
      final server = await fetchAcceptedVersion();
      if (server == null && local != null) {
        // This device accepted while the network was gone (see [accept]) and
        // the row never landed. Land it now, rather than showing the terms
        // again to somebody who has already read them.
        await recordAcceptance(local);
        _version = local;
      } else {
        _version = server;
        if (server != null) await _writeLocal(uid, server);
      }
    } catch (e) {
      // Not a silent catch, and not a fallback either — the local answer is
      // already in _version. This only says so out loud.
      debugPrint('[terms] server read failed (${e.runtimeType}); '
          'local=${_version ?? 'none'}');
    }
    accepted.value = !needsAcceptance;
  }

  /// Record that the current version was accepted.
  ///
  /// The local marker is written FIRST and on purpose. This screen sits in
  /// front of the whole app, so a failed write on a bad connection would
  /// otherwise be a lockout with no way past it — accept, fail, look at the
  /// terms again, forever. The marker lets them in; [load] posts the row on the
  /// next launch that reaches the server.
  static Future<void> accept() async {
    await _writeLocal(currentAccount(), milesTermsVersion);
    _version = milesTermsVersion;
    accepted.value = true;
    await recordAcceptance(milesTermsVersion);
  }

  /// Forget everything this process learned. Sign-out and account switch.
  static void reset() {
    _version = null;
    accepted.value = false;
  }

  static Future<int?> _fetchAcceptedVersion() async {
    final rows = await SupabaseService.client
        .from('tos_acceptances')
        .select('version')
        .order('version', ascending: false)
        .limit(1)
        .timeout(const Duration(seconds: 10));
    if (rows.isEmpty) return null;
    return (rows.first['version'] as num?)?.toInt();
  }

  static Future<void> _recordAcceptance(int version) async {
    try {
      await SupabaseService.client.from('tos_acceptances').insert({
        'version': version,
        'build': ReleaseGate.buildNumber,
      }).timeout(const Duration(seconds: 10));
    } on PostgrestException catch (e) {
      // 23505: the row is already there, written from this account's other
      // phone or by an earlier attempt. That is the state this call wanted.
      if (e.code != '23505') rethrow;
    }
  }

  // Keyed by account. A bare key would hand the second person to sign in on a
  // handset the first person's acceptance, which is the same device-scoped
  // leak that FCM tokens and cached couple ids have already caused here.
  static String _key(String? uid) => 'miles_tos_v1_${uid ?? 'anon'}';

  static Future<int?> _readLocal(String? uid) async =>
      (await SharedPreferences.getInstance()).getInt(_key(uid));

  static Future<void> _writeLocal(String? uid, int version) async =>
      (await SharedPreferences.getInstance()).setInt(_key(uid), version);
}
