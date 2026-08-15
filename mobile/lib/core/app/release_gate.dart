import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_service.dart';

/// Whether this build is still allowed to talk to the backend.
///
/// This app is sideloaded. There is no store, no update prompt, nothing that
/// pushes a new version — so "we will change the server once everyone has
/// updated" describes an event that never happens. With more than a handful of
/// users some fraction is always months behind, permanently, and a backend
/// change that assumes otherwise breaks them silently and forever.
///
/// That is not a hypothetical: closing the public media bucket was blocked on
/// exactly this, waiting for an install day that does not exist for a fleet.
///
/// So a breaking change goes in three steps instead of one:
///   1. ship a build that tolerates the change
///   2. raise app_release.min_build
///   3. make the change
/// Anyone below min_build is told to update rather than discovering it as a
/// broken screen.
class ReleaseGate {
  ReleaseGate._();

  /// This build. Bump with every release that a server change will depend on.
  /// Kept here rather than read from pubspec because the number that matters is
  /// the one the SERVER compares against, and it has to be legible in a diff.
  static const buildNumber = 35;

  /// The human-facing version, shown in Settings > About. Kept beside
  /// [buildNumber] and mirrored from pubspec's `version:` — the About card used
  /// to hardcode 'v0.1.0', which was still saying 0.1.0 at build 30.
  static const versionName = '0.1.0';

  static bool _blocked = false;
  static String? _message;

  static bool get isBlocked => _blocked;
  static String get message =>
      _message ?? 'Please update to keep using the app.';

  /// The newest build the server knows about, and where to get it. Read from the
  /// same `app_release` row as the gate above so the self-updater (UpdateService)
  /// costs no second fetch. `latestBuild` defaults to this build, so "no newer
  /// version" is the safe answer when the column is absent.
  static int latestBuild = buildNumber;
  static String? apkUrl;
  static String? apkSha256;
  static String? latestVersionName;

  /// Checked at startup, before sign-in — an out-of-date build may be broken in
  /// ways that stop it reaching a session at all.
  ///
  /// Fails OPEN. If the check itself cannot run (offline, project paused, table
  /// missing on a fresh environment) the app carries on: locking everyone out
  /// because a gate was unreachable is a worse outage than the one it guards.
  static Future<void> check() async {
    try {
      final row = await SupabaseService.client
          .from('app_release')
          .select(
            'min_build, latest_build, message, '
            'apk_url, apk_sha256, latest_version_name',
          )
          .limit(1)
          .maybeSingle();
      if (row == null) return;
      final min = (row['min_build'] as num?)?.toInt() ?? 1;
      _blocked = buildNumber < min;
      _message = row['message'] as String?;
      latestBuild = (row['latest_build'] as num?)?.toInt() ?? buildNumber;
      apkUrl = row['apk_url'] as String?;
      apkSha256 = row['apk_sha256'] as String?;
      latestVersionName = row['latest_version_name'] as String?;
      if (_blocked) {
        debugPrint('[release] build $buildNumber is below the minimum $min');
      }
    } catch (e) {
      debugPrint('[release] gate unreachable, allowing: ${e.runtimeType}');
    }
  }
}
