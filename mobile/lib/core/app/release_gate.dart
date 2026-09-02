import 'dart:async';

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
  static const buildNumber = 74;

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
  /// block screen and the switches read values frozen at process start.
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

  /// The newest build the server knows about, from the same `app_release`
  /// row as the gate above. Defaults to this build, so "no newer version" is
  /// the safe answer when the column is absent. Informational since the
  /// self-updater was retired (BRAIN §258): a change still bumps [revision].
  static int latestBuild = buildNumber;

  /// Whether this fleet has been declared ready to stop writing chat message
  /// bodies in the clear.
  ///
  /// Server-side because it cannot be a release: the instant one client writes
  /// cipher-only, every client that has not updated draws a blank bubble, and
  /// [check] fails open so no build number proves they are gone. The operator
  /// flips one row when the `sealed` telemetry says the fleet can read
  /// ciphertext, and flips it back in one statement if it cannot.
  ///
  /// Defaults FALSE and stays false on ANY failure — an unreachable gate, a
  /// project that has auto-paused, a column that does not exist yet on a fresh
  /// environment. Every one of those must mean "keep writing plaintext", never
  /// "stop", because the failure mode of guessing wrong is unreadable messages.
  static bool chatCipherOnly = false;

  /// Whether the fleet's UI sounds have been remotely silenced.
  ///
  /// Named as a KILL, not an enable, because the safe direction here is the
  /// opposite of the flag above. Cipher-only must fail OFF; a
  /// working sound layer must fail ON — an unreachable gate or an unmigrated
  /// environment should leave sound following the on-device toggle, not strip
  /// a shipped feature from every offline client. `== true` on an absent
  /// column reads false, and false means "not killed".
  ///
  /// The kill exists for one scenario: a device-population audio bug found in
  /// the field — an OEM Vorbis path that ANRs, a focus fight with a dialer —
  /// where the way back has to be one UPDATE, not a release cycle waiting on
  /// installs.
  static bool uiSoundKilled = false;

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

  /// The app-level native handler (MainActivity's 'miles/updater' channel,
  /// named for the self-updater it once also served); it answers 'channel' on
  /// both flavours.
  static const _updater = MethodChannel('miles/updater');
  static bool _channelKnown = false;

  /// Whether [channel] is the platform's answer or merely the safe default.
  ///
  /// The block screen needs the difference. 'sideload' means two things there —
  /// "this install cannot use the store" and "nobody has told us yet" — and
  /// treating the second as the first is how a Play install whose platform call
  /// timed out ends up on a screen with no way out at all.
  static bool get channelKnown => _channelKnown;

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
      // The screens that read the channel have nothing else to tell them it
      // moved: [applyRow]'s bump fires only when the FLOOR or the latest build
      // changes, so a late answer that merely swaps the block screen's exit
      // (store link instead of the sideload dead end) would never be painted.
      revision.value++;
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
  /// [budget] bounds the whole read, because the first frame waits on this.
  ///
  /// Nothing here is worth a long wait: every failure path already falls open,
  /// so a gate that times out allows exactly what a gate that answers "no row"
  /// allows. Left unbounded it is the slowest thing before runApp — three
  /// column sets tried in series, each one four postgrest attempts with 1/2/4s
  /// backoff under a 30s ceiling, so a socket that is open but dead (captive
  /// portal, half-open TCP) held the launch drawable for minutes with no UI and
  /// no error. An ordinary offline launch spent ~21s of that in backoff alone.
  static Future<void> check({
    Duration budget = const Duration(seconds: 6),
  }) async {
    _lastCheck = DateTime.now();
    // Settled before the row is read — the row's meaning depends on it.
    await _loadChannel();
    // PostgREST 400s the WHOLE select when ONE column is missing, and a
    // swallowed 400 here would not fail open — it would silently drop every
    // switch this row carries (min_build, chat_cipher_only, ui_sound_kill) on
    // an environment that lacks the newest column. So the column list degrades
    // in steps, newest column first, and each step gives up only what the
    // environment below it cannot answer.
    const withSoundKill = 'min_build, min_build_play, latest_build, message, '
        'chat_cipher_only, ui_sound_kill';
    const withCipher = 'min_build, min_build_play, latest_build, message, '
        'chat_cipher_only';
    const legacy = 'min_build, latest_build, message';
    const columnSets = [withSoundKill, withCipher, legacy];
    try {
      await _readRow(columnSets).timeout(budget);
    } on TimeoutException {
      debugPrint('[release] gate did not answer within '
          '${budget.inSeconds}s, allowing');
    }
  }

  static Future<void> _readRow(List<String> columnSets) async {
    for (final columns in columnSets) {
      try {
        final row = await SupabaseService.client
            .from('app_release')
            .select(columns)
            .limit(1)
            .maybeSingle();
        if (row == null) return;
        applyRow(row);
        return;
      } catch (e) {
        // Named per step. A gate that degrades in silence looks identical to a
        // gate that is working, and the difference is which columns the fleet
        // is actually being governed by.
        debugPrint('[release] column set refused (${e.runtimeType}), '
            'falling back');
      }
    }
    debugPrint('[release] gate unreachable, allowing');
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
    // `== true`, not a cast: the fallback select above omits this column
    // entirely, so on a rolled-back or fresh environment the key is absent and
    // this must read false. Anything other than an explicit true keeps chat
    // writing plaintext, which is the safe direction.
    chatCipherOnly = row['chat_cipher_only'] == true;
    final wasSoundKilled = uiSoundKilled;
    // `== true` again, but note the polarity: absent reads false, and false
    // means sound stays ON (following the local toggle). The safe failure for
    // this flag is a working feature, which is why the column is a kill.
    uiSoundKilled = row['ui_sound_kill'] == true;
    if (_blocked != wasBlocked ||
        latestBuild != wasLatest ||
        uiSoundKilled != wasSoundKilled) {
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
