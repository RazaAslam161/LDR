import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  static const buildNumber = 46;

  /// The human-facing version, shown in Settings > About. Kept beside
  /// [buildNumber] and mirrored from pubspec's `version:` — the About card used
  /// to hardcode 'v0.1.0', which was still saying 0.1.0 at build 30.
  static const versionName = '0.1.0';

  /// A literal that CHANGES EVERY BUILD, so a release can prove its Dart is the
  /// Dart it claims to be.
  ///
  /// Const interpolation of a const int is a compile-time constant, so this
  /// lands in libapp.so as the actual characters `miles-build-37`. release.sh
  /// greps for the number pubspec says it just built; a snapshot Flutter reused
  /// from an earlier build carries the earlier number and the release stops.
  ///
  /// The guard this replaces looked for 'Update available', which had been in
  /// every build since 31 — so it passed on exactly the failure it was written
  /// to catch, and six releases shipped build-31 Dart under fresh versionCodes.
  static const buildStamp = 'miles-build-$buildNumber';

  static bool _blocked = false;
  static String? _message;

  /// Bumped whenever a check CHANGES the answer, so the UI can react without a
  /// restart.
  ///
  /// [check] used to run once in main() into plain statics, which meant a client
  /// already running when a release was published never learned about it: the
  /// update sheet and the block screen both read values frozen at process start.
  /// A phone that Android keeps alive for days therefore sat on a superseded
  /// build indefinitely, and the release reached only whoever happened to cold
  /// start afterwards. That is most of a fleet, not an edge case.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// Guards against re-checking on every task switch. A resume is cheap to
  /// observe and a round trip is not.
  static DateTime? _lastCheck;

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

  /// Which channel this install is — 'sideload' or 'play', as the Android
  /// side's BuildConfig reports it. The two fleets need separate floors:
  /// raising min_build tells sideload clients to install the published APK
  /// over themselves, an instruction a Play install must never receive, and
  /// the Play rollout will trail the sideload one anyway.
  ///
  /// Defaults to 'sideload' and stays there on ANY failure — every client
  /// shipped before the play channel existed is sideload, so an unknown
  /// channel must behave as one or an error would move the installed base
  /// onto the wrong floor. Writable so tests can stand in either fleet
  /// without a platform channel.
  static String channel = 'sideload';

  /// The same native handler UpdateService talks to; it answers 'channel' on
  /// both flavours.
  static const _updater = MethodChannel('miles/updater');
  static bool _channelKnown = false;

  /// Exposed so a test can prove the safety-critical half: ANY failure of
  /// the platform query leaves the channel at 'sideload', because moving an
  /// unknown client onto the play floor would unblock phones min_build
  /// exists to block.
  @visibleForTesting
  static Future<void> loadChannelForTest() => _loadChannel();

  static Future<void> _loadChannel() async {
    if (_channelKnown) return;
    try {
      channel = await _updater
              .invokeMethod<String>('channel')
              .timeout(const Duration(seconds: 2)) ??
          'sideload';
      _channelKnown = true;
    } catch (e) {
      // Non-Android host, or a native side that predates the method. The
      // default stands; the next check() may ask again.
      debugPrint('[release] channel query failed, assuming sideload: '
          '${e.runtimeType}');
    }
  }

  /// Checked at startup, before sign-in — an out-of-date build may be broken in
  /// ways that stop it reaching a session at all.
  ///
  /// Fails OPEN. If the check itself cannot run (offline, project paused, table
  /// missing on a fresh environment) the app carries on: locking everyone out
  /// because a gate was unreachable is a worse outage than the one it guards.
  static Future<void> check() async {
    _lastCheck = DateTime.now();
    // Settled before the row is read — the row's meaning depends on it.
    await _loadChannel();
    try {
      final row = await SupabaseService.client
          .from('app_release')
          .select(
            'min_build, min_build_play, latest_build, message, '
            'apk_url, apk_sha256, latest_version_name',
          )
          .limit(1)
          .maybeSingle();
      if (row == null) return;
      applyRow(row);
    } catch (e) {
      // An environment without min_build_play 400s the WHOLE select, and one
      // swallowed 400 here would not fail open — it would turn the updater
      // off: apkUrl/latestBuild never load, UpdateService.available stays
      // false, and the sideload fleet quietly loses its only update channel.
      // Retry once with the pre-20260817150000 column list so a stale or
      // rolled-back environment degrades to the old behaviour instead.
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
        applyRow(row);
      } catch (e2) {
        debugPrint('[release] gate unreachable, allowing: ${e2.runtimeType}');
      }
    }
  }

  /// Parsing and change detection, split from the fetch so it can be exercised
  /// without a backend.
  ///
  /// The [revision] bump is the part that regresses silently: remove it and
  /// everything still compiles, every test that does not assert on it still
  /// passes, and the app quietly goes back to learning about a release only on
  /// a cold start — which is the bug this whole path exists to fix.
  @visibleForTesting
  static void applyRow(Map<String, dynamic> row) {
    // Each fleet reads its own floor. Shipped sideload clients predate
    // min_build_play and keep reading min_build unchanged; the play channel
    // reads its own column, and until the owner deliberately raises it an
    // absent or null min_build_play means 0 — play never blocks by default,
    // because blocking is only useful where the way out (a newer build on the
    // store) actually exists yet.
    final min = channel == 'play'
        ? ((row['min_build_play'] as num?)?.toInt() ?? 0)
        : ((row['min_build'] as num?)?.toInt() ?? 1);
    final wasBlocked = _blocked;
    final wasLatest = latestBuild;
    _blocked = buildNumber < min;
    _message = row['message'] as String?;
    latestBuild = (row['latest_build'] as num?)?.toInt() ?? buildNumber;
    apkUrl = row['apk_url'] as String?;
    apkSha256 = row['apk_sha256'] as String?;
    latestVersionName = row['latest_version_name'] as String?;
    if (_blocked != wasBlocked || latestBuild != wasLatest) {
      revision.value++;
    }
    // Unconditional, and it is not only a trace: reading buildStamp is what
    // keeps the literal in the snapshot. A const string nothing references is
    // one the tree-shaker may drop, and release.sh greps for it to prove the
    // Dart in the artifact is the Dart it just compiled.
    debugPrint('[release] $buildStamp checked in, server says $latestBuild');
    if (_blocked) {
      debugPrint('[release] build $buildNumber is below the minimum $min');
    }
  }

  /// Re-read the gate when the app comes back to the foreground.
  ///
  /// Publishing a release changes a row on the server; without this the change
  /// reaches only clients that cold start afterwards. Throttled because a resume
  /// fires on every task switch, and skipped once blocked — the block screen is
  /// terminal, so there is nothing a further check could tell it.
  static Future<void> recheck() async {
    if (_blocked) return;
    final last = _lastCheck;
    if (last != null && DateTime.now().difference(last) < _recheckAfter) return;
    await check();
  }

  static const _recheckAfter = Duration(minutes: 15);
}
