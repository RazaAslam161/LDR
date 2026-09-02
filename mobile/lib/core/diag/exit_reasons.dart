import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A process that died last time, reported by the launch that follows it.
///
/// [reason] is Android's `ApplicationExitInfo` code; [description] is the
/// OS's one-line account of the death (the signal, the ANR subject, the
/// uncaught exception's class). Neither carries message text or a name.
class ProcessExit implements Exception {
  const ProcessExit(this.reason, this.description);

  final int reason;
  final String description;

  @override
  String toString() => 'ProcessExit($reason): $description';
}

/// Crash and ANR visibility without a crash SDK.
///
/// The app deliberately ships no third-party reporter, so a native crash in
/// WebRTC or Mapbox, an ANR, or a Dart error the global nets never saw used
/// to leave no trace anywhere. Android has kept a record of every process
/// death since API 30 (`ActivityManager.getHistoricalProcessExitReasons`);
/// this reads it on the next launch and files what is new to `client_errors`
/// through the same reporter every other kind uses. A watermark in prefs
/// keeps each death reported once, and the first run after this shipped sets
/// the watermark without reporting, so deaths of OLDER builds are never
/// filed under the new build number.
class ExitReasons {
  ExitReasons._();

  /// MainActivity's app-level channel; 'exitReasons' answers a list of maps
  /// with reason, description, timestamp, importance and, for ANR and
  /// native crashes on API 31+, the first part of the trace.
  static const _channel = MethodChannel('miles/updater');
  static const _seenKey = 'exit_reasons_seen_until';

  /// Stands in for the platform call under test.
  @visibleForTesting
  static Future<List<Map<Object?, Object?>>?> Function()? fetchForTest;

  /// Which deaths are worth a row. Low-memory kills, user swipes and package
  /// updates are the OS doing its job; these five are the app failing.
  static String? kindFor(int reason) => switch (reason) {
        4 => 'exit-crash', // REASON_CRASH: uncaught Java/Kotlin exception
        5 => 'exit-native', // REASON_CRASH_NATIVE: SIGSEGV and friends
        6 => 'exit-anr', // REASON_ANR
        7 => 'exit-init', // REASON_INITIALIZATION_FAILURE
        9 => 'exit-resources', // REASON_EXCESSIVE_RESOURCE_USAGE
        _ => null,
      };

  /// Files every death newer than the watermark; returns how many.
  ///
  /// Never throws: a missing channel (a widget test, an old Android), a
  /// refused read or a prefs store that will not answer is worth a debug
  /// line, not a startup failure — this is the first thing main() runs.
  static Future<int> report() async {
    try {
      final seam = fetchForTest;
      final list = seam != null
          ? await seam()
          : await _channel.invokeListMethod<Map<Object?, Object?>>('exitReasons');
      if (list == null) return 0;
      return await _file(list);
    } catch (e) {
      debugPrint('[exit] reasons unavailable: ${e.runtimeType}');
      return 0;
    }
  }

  static Future<int> _file(List<Map<Object?, Object?>> list) async {
    final prefs = await SharedPreferences.getInstance();
    final seenUntil = prefs.getInt(_seenKey);
    var newest = seenUntil ?? 0;
    var reported = 0;
    for (final m in list) {
      final ts = (m['timestamp'] as num?)?.toInt() ?? 0;
      if (ts > newest) newest = ts;
      // First run: learn where the record stands and report nothing, so a
      // crash of build N-1 is never filed as build N's.
      if (seenUntil == null || ts <= seenUntil) continue;
      final kind = kindFor((m['reason'] as num?)?.toInt() ?? 0);
      if (kind == null) continue;
      final description = (m['description'] as String?) ?? '';
      final trace = (m['trace'] as String?) ?? '';
      ErrorReporter.report(
        ProcessExit((m['reason'] as num).toInt(), description),
        // The reporter dedups on the first line of the stack, so that line is
        // the description and the instant — two deaths of the same kind in
        // one run are two rows — and the OS trace, when there is one, rides
        // below it.
        StackTrace.fromString(
          trace.isEmpty ? '$description @$ts' : '$description @$ts\n$trace',
        ),
        kind: kind,
        // Past the per-run cap: a launch that follows a crash has nothing
        // more important to say than what killed the last one.
        force: true,
      );
      reported++;
    }
    if (newest == 0) newest = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt(_seenKey, newest);
    return reported;
  }
}
