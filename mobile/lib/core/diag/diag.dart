import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The only thing that tells anyone this app is broken.
///
/// It is sideloaded, so there is no store console; disguised, so there is no
/// support channel that could name it; and it had no crash reporter at all.
/// What stood in for one was a debugPrint, which reaches logcat, which reaches
/// whichever of the two handsets has a cable in it — the same one-sided
/// blindness that had calls and presence "fixed" three times each. A build that
/// throws on launch for every user looks exactly like a build nobody opened.
///
/// Best-effort by construction. Nothing here is awaited on a user path, the
/// send is wrapped, and a report that cannot be delivered is dropped rather
/// than surfaced: a reporter that can break the app is worse than no reporter.
class ErrorReporter {
  ErrorReporter._();

  /// Five a run, and never the same failure twice.
  ///
  /// A widget that throws in build() throws on every frame — sixty rows a
  /// second, from every affected handset at once. The server drops the excess
  /// (client_errors_rate_limit), but a bound the client does not also keep is
  /// one paid for in requests.
  static const _maxPerRun = 5;
  static final _seen = <String>{};
  static var _sent = 0;

  /// The answer is in the top frames; below them is the framework stack, which
  /// is identical for every error of that kind.
  static const _maxFrames = 16;
  static const _maxStackChars = 2000;

  /// Matches the column ceilings in 20260601007800. An insert the server
  /// rejects is a report nobody ever sees.
  static const _maxTypeChars = 64;
  static const _maxDetailChars = 64;

  static void report(Object error, StackTrace? stack, {required String kind}) {
    // The raw text never leaves the device, so a debug build has every reason
    // to print it and a release build every reason not to: logcat is readable
    // over adb, the message may hold plaintext, and the product's name is not
    // something this app writes down.
    if (kDebugMode) debugPrint('$kind error: $error\n$stack');

    if (_sent >= _maxPerRun) return;
    final type = _cap(error.runtimeType.toString(), _maxTypeChars);
    final trace = _stack(stack);
    if (!_seen.add('$type\n${trace.split('\n').first}')) return;
    _sent++;

    final detail = _detail(error);
    unawaited(_send({
      'build': ReleaseGate.buildNumber,
      'kind': kind,
      'error_type': type,
      if (detail != null) 'detail': _cap(detail, _maxDetailChars),
      'stack': trace,
    },),);
  }

  static Future<void> _send(Map<String, Object?> row) async {
    try {
      await SupabaseService.client.from('client_errors').insert(row);
    } catch (_) {
      // Signed out, offline, rate-limited, or thrown before SupabaseService
      // finished initialising — all of which mean the row is lost and the app
      // carries on. Reporting a reporting failure is a loop with nowhere to
      // report to.
    }
  }

  /// What "redacted" means here.
  ///
  /// `error.toString()` is the obvious field to send and the one that can never
  /// be sent. Every exception in this app is thrown by code holding a couple's
  /// plaintext, and `StateError('no key for ${m.body}')` is one keystroke from
  /// shipping a private message inside a crash report. Cleaning that text
  /// afterwards is the denylist that already lost here once, to a 55-character
  /// sentence — the reasoning is written out at diag_event.dart:86.
  ///
  /// So the message is discarded, not cleaned, and what survives is the machine
  /// code — read from a typed field rather than parsed out of prose. It is the
  /// difference between "RLS refused it" and "the column is gone", which the
  /// exception type alone cannot tell you. Everything else reports as null.
  static String? _detail(Object error) => switch (error) {
        PostgrestException(:final code) => code,
        AuthException(:final code) => code,
        SocketException(osError: final os?) => 'errno.${os.errorCode}',
        _ => null,
      };

  /// Frames name packages, files, lines and symbols — the code's identity,
  /// never the user's.
  static String _stack(StackTrace? stack) {
    if (stack == null) return '';
    // `package:miles/` opens most lines, costs a fifth of the budget, and is
    // the one string in a report that names the product.
    final frames = stack
        .toString()
        .split('\n')
        .take(_maxFrames)
        .join('\n')
        .replaceAll('package:miles/', '');
    return _cap(frames, _maxStackChars);
  }

  static String _cap(String v, int max) =>
      v.length <= max ? v : v.substring(0, max);
}

/// Retired. Nothing below records anything.
///
/// This was a per-couple field trace for three bugs that have since been fixed,
/// and it stopped working in build 10: [record] returned on a flag that only
/// the test reset ever set, so all 75 call sites have written nothing since —
/// realtime's CHANNEL_ERROR and the push-received receipt included. The header
/// that used to sit here claimed three sinks and an opt-in switch, and all
/// three claims were false: Settings has no switch, `_file` was never assigned
/// so the disk ring wrote nothing either, and the server copy it promised was
/// narrowed to own-rows-only and then emptied (20260601005850, 20260601006100).
///
/// It is not coming back behind a server flag. One couple produced 21,448 rows
/// and 9 MB in a single day, and diag_events grew to 65% of the database
/// (20260601005600); a switch that turns that on for a fleet at once is a
/// larger outage than any bug it would explain, and the events it carries are
/// dominated by a 30-second presence heartbeat and ICE bursts rather than by
/// anything that means "broken". [ErrorReporter] is what that was reaching for,
/// bounded by construction.
///
/// [record] and [span] stay as no-ops so their 71 remaining call sites still
/// compile. Removing them is mechanical and belongs in its own commit.
class Diag {
  Diag._();

  static const _enabledKey = 'diag_enabled';

  /// Retires diagnostics on this handset. Still needed on every launch until
  /// every install has run it once.
  ///
  /// - The stored `diag_enabled` gated the upload, and it is true on any
  ///   handset where it was ever switched on. Without clearing it, an upgrade
  ///   removes the off switch and leaves the uploads running forever.
  /// - `diag.ndjson` was written on every run regardless of the flag, so a file
  ///   of call, presence and chat traces is sitting in the documents directory
  ///   of every install. Nothing can read it now, and an unreadable record of
  ///   who called whom and when is exactly what this app is meant not to keep.
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_enabledKey);
      final dir = await getApplicationDocumentsDirectory();
      final stale = File('${dir.path}/diag.ndjson');
      if (stale.existsSync()) await stale.delete();
    } catch (e) {
      // Diagnostics failing to retire must never stop the app starting.
      debugPrint('[diag] retire failed: $e');
    }
  }

  static void record(
    DiagArea area,
    String name, {
    String? corr,
    Map<String, Object?> fields = const {},
  }) {}

  static void Function({String? outcome, Map<String, Object?> fields}) span(
    DiagArea area,
    String name, {
    String? corr,
  }) =>
      ({String? outcome, Map<String, Object?> fields = const {}}) {};
}
