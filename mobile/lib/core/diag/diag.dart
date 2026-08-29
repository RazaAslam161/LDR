import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
/// send is wrapped, and a report that cannot be delivered waits on disk for a
/// launch that can deliver it — see [flushBuffered]. A reporter that can break
/// the app is worse than no reporter, and a reporter that loses the launch
/// crash — the one report a broken build produces — is barely one at all.
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

  /// A fresh run: the dedup set, the cap, and both seams back to real.
  @visibleForTesting
  static void resetForTest() {
    _seen.clear();
    _sent = 0;
    insertRow = _insertRow;
    hasSession = _hasSession;
  }

  /// The answer is in the top frames; below them is the framework stack, which
  /// is identical for every error of that kind.
  static const _maxFrames = 16;
  static const _maxStackChars = 2000;

  /// Matches the column ceilings in 20260601007800. An insert the server
  /// rejects is a report nobody ever sees.
  static const _maxTypeChars = 64;
  static const _maxDetailChars = 64;

  /// [force] lets one report past the per-run cap — never past the dedup.
  /// The data export's single end-of-run shortfall row is why it exists: a
  /// run failing across hundreds of items shares its broken backend with the
  /// rest of the app, so by the time that one summary row is built the cap
  /// is usually already spent on the same outage's other reports.
  static void report(
    Object error,
    StackTrace? stack, {
    required String kind,
    bool force = false,
  }) {
    // The raw text never leaves the device, so a debug build has every reason
    // to print it and a release build every reason not to: logcat is readable
    // over adb, the message may hold plaintext, and the product's name is not
    // something this app writes down.
    if (kDebugMode) debugPrint('$kind error: $error\n$stack');

    if (!force && _sent >= _maxPerRun) return;
    final type = _cap(error.runtimeType.toString(), _maxTypeChars);
    final trace = _stack(stack);
    // kind is part of the key: chat-fetch and shared-media can both die
    // inside Message.fromJson with the same type and first frame, and one
    // must not suppress the other for the whole run.
    if (!_seen.add('$kind\n$type\n${trace.split('\n').first}')) return;
    _sent++;

    final detail = _detail(error);
    final row = <String, Object?>{
      'build': ReleaseGate.buildNumber,
      'kind': kind,
      'error_type': type,
      if (detail != null) 'detail': _cap(detail, _maxDetailChars),
      'stack': trace,
    };
    unawaited(_send(row));
  }

  static Future<void> _send(Map<String, Object?> row) async {
    try {
      await insertRow(row);
    } catch (e) {
      // Signed out, offline, rate-limited, or thrown before SupabaseService
      // finished initialising — and that last one is the report that matters
      // most: a build that dies before init() produces exactly one row, and
      // this catch is where it used to vanish. Parked on disk instead, for
      // [flushBuffered] to deliver from a launch that gets further than this
      // one did. The row already went through redaction when it was built —
      // type, machine code, frames, never message text — so nothing waiting
      // in the buffer is anything a report was not already allowed to carry.
      debugPrint('[report] insert failed (${e.runtimeType}); buffering');
      await _buffer(row);
    }
  }

  /// The insert, injectable so the buffer tests can run without a database —
  /// the seam `TermsGate.fetchAcceptedVersion` cut for the same reason:
  /// `SupabaseService.client` is a `late final` and throws anywhere the app
  /// has not booted.
  @visibleForTesting
  static Future<void> Function(Map<String, Object?> row) insertRow = _insertRow;

  static Future<void> _insertRow(Map<String, Object?> row) =>
      SupabaseService.client.from('client_errors').insert(row);

  /// Whether an insert can land at all. client_errors is insert-only for
  /// `authenticated`, so with no session every attempt is a guaranteed
  /// failure — and each one would burn one of a buffered row's three tries on
  /// a launch that could never have delivered it. A seam because the real
  /// answer goes through `SupabaseService.client`.
  @visibleForTesting
  static bool Function() hasSession = _hasSession;

  static bool _hasSession() =>
      SupabaseService.client.auth.currentSession != null;

  /// Twenty rows, oldest out first, three launches each to land.
  ///
  /// Twenty is four runs of the per-run cap — enough to hold a broken build's
  /// whole story without ever being a disk-growth vector on a handset that
  /// stays broken for weeks. Oldest dropped first because the newest rows
  /// describe the build installed NOW, which is the one that can be fixed.
  static const _bufferKey = 'client_errors_pending';
  static const _bufferMax = 20;
  static const _maxFlushTries = 3;

  /// SharedPreferences rather than a file under the support directory: the
  /// rows are small, bounded and already strings, [Diag] keeps its own flag
  /// there, and the plugin's read-modify-write runs synchronously against its
  /// in-memory cache — so two reports failing in the same run cannot lose
  /// each other's rows the way two unsynchronised file writes can.
  static Future<void> _buffer(Map<String, Object?> row) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList(_bufferKey) ?? <String>[];
      pending.add(jsonEncode({'tries': 0, 'row': row}));
      while (pending.length > _bufferMax) {
        pending.removeAt(0);
      }
      await prefs.setStringList(_bufferKey, pending);
    } catch (e) {
      // The end of the line: a reporter that cannot reach its own disk has
      // nowhere left to say so but a debug console.
      debugPrint('[report] buffer write failed (${e.runtimeType})');
    }
  }

  /// Deliver what previous runs could not. Called once per launch from
  /// main(), after `SupabaseService.init` has assigned the client — getting
  /// that far is what "a launch that works" means to the rows waiting here.
  ///
  /// Each attempt stamps the row's `tries`, and the third failure drops it: a
  /// row the server refuses by policy — a check constraint, a column mismatch
  /// — would otherwise ride the buffer forever, re-failing on every launch.
  /// The list is taken OFF disk before the first insert and the survivors
  /// written back after the last, so a crash mid-flush loses rows rather than
  /// duplicating them, which for crash reports is the cheap direction. The
  /// write-back re-reads the list instead of overwriting it, because a live
  /// report failing DURING the flush has already buffered itself into it.
  static Future<void> flushBuffered() async {
    try {
      if (!hasSession()) return;
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList(_bufferKey);
      if (pending == null || pending.isEmpty) return;
      await prefs.remove(_bufferKey);
      final kept = <String>[];
      var delivered = 0;
      var dropped = 0;
      for (final entry in pending) {
        Map<String, Object?>? row;
        var tries = 0;
        try {
          final decoded = jsonDecode(entry) as Map<String, dynamic>;
          tries = (decoded['tries'] as num? ?? 0).toInt();
          row = (decoded['row'] as Map<String, dynamic>?)
              ?.cast<String, Object?>();
        } catch (e) {
          debugPrint('[report] undecodable buffered row (${e.runtimeType})');
        }
        if (row == null) {
          dropped++;
          continue;
        }
        try {
          await insertRow(row);
          delivered++;
        } catch (e) {
          if (tries + 1 >= _maxFlushTries) {
            dropped++;
            debugPrint('[report] dropped after $_maxFlushTries tries '
                '(${e.runtimeType})');
          } else {
            kept.add(jsonEncode({'tries': tries + 1, 'row': row}));
          }
        }
      }
      if (kept.isNotEmpty) {
        final current = prefs.getStringList(_bufferKey) ?? <String>[];
        final merged = [...kept, ...current];
        while (merged.length > _bufferMax) {
          merged.removeAt(0);
        }
        await prefs.setStringList(_bufferKey, merged);
      }
      debugPrint('[report] flushed $delivered of ${pending.length}; '
          'kept ${kept.length}, dropped $dropped');
    } catch (e) {
      // Never rethrows. This runs unawaited in main(), and an error escaping
      // an unawaited future lands in platformDispatcher.onError — which calls
      // report(), which is the loop this class must never close.
      debugPrint('[report] flush failed (${e.runtimeType})');
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
        // The typed code only, never the message — a PlatformException from
        // the video player can carry a signed URL in its message, and a
        // StorageException names the object it refused.
        PlatformException(:final code) => code,
        StorageException(:final statusCode) => 'storage.$statusCode',
        // Safe by construction: counts and a class name, assembled by the
        // reporter itself. Without this case the whole point of a shortfall
        // report — the N of M — died right here in the switch.
        ParseShortfall(:final where, :final parsed, :final of, :final first) =>
          '$where: $parsed/$of, first=$first',
        ShareQualityDigest(
          :final codec,
          :final finalRung,
          :final topRung,
          :final durationS,
          :final climbs,
          :final falls,
          :final cpu,
          :final bw,
          :final fpsP50,
          :final bweKbps,
          :final endReason
        ) =>
          '$codec r$finalRung/$topRung ${durationS}s c$climbs f$falls '
              'cpu$cpu bw$bw fps$fpsP50 bwe$bweKbps e$endReason',
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
/// three claims were false: Settings has no switch, `_file` was left null when
/// [init] became the retirement chore so the disk ring wrote nothing either,
/// and the server copy it promised was narrowed to own-rows-only and then
/// emptied (20260601005850, 20260601006100).
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
  /// - Builds before 10 wrote `diag.ndjson` on every run regardless of the
  ///   flag, so a file of call, presence and chat traces is sitting in the
  ///   documents directory of every install. Nothing can read it now, and an
  ///   unreadable record of who called whom and when is exactly what this app
  ///   is meant not to keep.
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

  /// In production this records nothing — [ErrorReporter] is what reports now.
  ///
  /// It still keeps a bounded in-memory ring WHEN A TEST ASKS FOR ONE, because
  /// a handful of tests assert on the trace rather than on state, and they are
  /// right to. `presence_route_observer_test.dart:169` is the example: the
  /// presence bug it covers was invisible in `myScreenProvider` — the local
  /// value read correctly either way, which is exactly why two full audits
  /// refuted every candidate — and only the sequence of recorded events showed
  /// it. Dropping the ring outright would delete that regression test along
  /// with the mechanism.
  ///
  /// Off unless [resetForTest] turns it on, so no shipped build allocates.
  static bool _capture = false;
  static const _ringMax = 200;
  static final List<DiagEvent> _ring = [];

  @visibleForTesting
  static List<DiagEvent> get recent => List.unmodifiable(_ring);

  @visibleForTesting
  static void resetForTest({bool capture = true}) {
    _capture = capture;
    _ring.clear();
  }

  static void record(
    DiagArea area,
    String name, {
    String? corr,
    Map<String, Object?> fields = const {},
  }) {
    if (!_capture) return;
    if (_ring.length >= _ringMax) _ring.removeAt(0);
    _ring.add(DiagEvent(
      seq: _ring.length,
      at: DateTime.now(),
      area: area,
      name: name,
      corr: corr,
      fields: fields,
    ),);
  }

  static void Function({String? outcome, Map<String, Object?> fields}) span(
    DiagArea area,
    String name, {
    String? corr,
  }) =>
      ({String? outcome, Map<String, Object?> fields = const {}}) {};
}

/// A decode shortfall, made reportable without ever being able to leak.
///
/// [ErrorReporter] discards message text by design, so a shortfall phrased as
/// a StateError reached the server as a bare 'StateError' — the count and the
/// failing class died on the way. This type carries them in fields the
/// `_detail` switch reads directly: two numbers and a class NAME, nothing a
/// row's contents could ride in on.
class ParseShortfall implements Exception {
  ParseShortfall(
    this.where, {
    required this.parsed,
    required this.of,
    required this.first,
  });

  /// Which fetch fell short — a code location, never data.
  final String where;
  final int parsed;
  final int of;

  /// runtimeType name of the first failure, e.g. 'FormatException'.
  final String first;

  @override
  String toString() => 'ParseShortfall';
}

/// How a screen share actually performed, reported once when it ends.
///
/// Safe by construction on the [ParseShortfall] model: rung indices, counts
/// and a codec slug, assembled by the share session itself — nothing
/// user-generated can ride in. The codec is the headline: it says from the
/// field whether hardware H.264 actually won negotiation, which no test on
/// this machine can prove.
class ShareQualityDigest implements Exception {
  ShareQualityDigest({
    required this.codec,
    required this.finalRung,
    required this.topRung,
    required this.durationS,
    required this.climbs,
    required this.falls,
    required this.cpu,
    required this.bw,
    required this.fpsP50,
    required this.bweKbps,
    required this.endReason,
  });

  /// Short codec slug from the outbound stats, e.g. 'h264'.
  final String codec;
  final int finalRung;
  final int topRung;
  final int durationS;
  final int climbs;
  final int falls;

  /// Samples the encoder spent cpu- or bandwidth-limited.
  final int cpu;
  final int bw;
  final int fpsP50;
  final int bweKbps;

  /// 0 = stopped normally, 1 = stalled after frames flowed, 2 = the encoder
  /// never produced a frame at all (the build-62 black-share class).
  final int endReason;

  @override
  String toString() => 'ShareQualityDigest';
}
