import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/supabase_service.dart';

/// Field evidence for the three mechanisms that keep failing.
///
/// Calls, receipts and presence all fail BETWEEN two phones, in two cities, on
/// two carriers. Every previous round diagnosed them from one side — a cable,
/// a logcat, a guess — and every previous round was wrong, including one theory
/// disproved by the user's own terminal. The missing thing was never analysis;
/// it was a record of what actually happened on BOTH devices, on ONE timeline.
///
/// So this writes to three places, and the redundancy is deliberate:
///   in memory  — the in-app viewer, so the person holding the failing phone
///                can see it without a computer.
///   on disk    — survives the process. A failed call is frequently followed by
///                the app being killed, which is exactly when the last twenty
///                events matter most.
///   on the server — the only copy that can be correlated with the partner's,
///                and the only one reachable when the partner is 1,000km away.
///
/// Everything is best-effort and nothing is awaited on a user path. A
/// diagnostic that can break a call is not a diagnostic.
class Diag {
  Diag._();

  static const _enabledKey = 'diag_enabled';

  /// On by default. This exists because three mechanisms are broken in the
  /// field and off-by-default instrumentation is instrumentation that is off
  /// on the phone that fails. Settings exposes the switch.
  static const _enabledDefault = true;

  static bool _enabled = _enabledDefault;
  static bool get enabled => _enabled;

  /// One app run. Two sessions from one device mean the app restarted between
  /// them — itself a fact worth seeing in a call trace.
  static final String sessionId = const Uuid().v4();

  static int _seq = 0;

  /// The viewer's window. Bounded so a long-running app cannot grow without
  /// limit; disk and server hold the rest.
  static const _ringSize = 1000;
  static final ListQueue<DiagEvent> _ring = ListQueue<DiagEvent>(_ringSize);

  static final List<DiagEvent> _pendingDisk = [];
  static final List<DiagEvent> _pendingUpload = [];

  /// Dropped rather than allowed to grow. An unbounded upload queue on a phone
  /// with no connectivity is a memory leak that shows up as a crash days later.
  static const _uploadQueueMax = 500;
  static int _dropped = 0;

  static String? _coupleId;
  static String? _userId;

  static Timer? _flushTimer;
  static bool _flushing = false;
  static File? _file;

  /// Rotated, not unbounded: two files of a megabyte each is enough to hold a
  /// failed call plus the minutes around it, and small enough to paste.
  static const _fileMaxBytes = 1024 * 1024;

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_enabledKey) ?? _enabledDefault;
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/diag.ndjson');
      _flushTimer ??=
          Timer.periodic(const Duration(seconds: 3), (_) => unawaited(flush()));
    } catch (e) {
      // Diagnostics failing to start must never stop the app starting.
      debugPrint('[diag] init failed: $e');
    }
    record(DiagArea.app, 'session_start', fields: {
      'session': sessionId,
      'debug': kDebugMode,
    });
  }

  static Future<void> setEnabled(bool v) async {
    _enabled = v;
    record(DiagArea.app, v ? 'diag_on' : 'diag_off');
    if (!v) {
      _pendingUpload.clear();
      _pendingDisk.clear();
    }
    try {
      await (await SharedPreferences.getInstance()).setBool(_enabledKey, v);
    } catch (_) {}
  }

  /// Uploads cannot start until the session resolves, because the row needs a
  /// couple to be scoped to. Events recorded before this still reach memory and
  /// disk, and are uploaded once binding happens — cold-start ordering bugs are
  /// one of the things being hunted, so losing the first seconds would defeat
  /// the purpose.
  static void bind({required String? coupleId, required String? userId}) {
    if (coupleId == _coupleId && userId == _userId) return;
    _coupleId = coupleId;
    _userId = userId;
    record(DiagArea.app, 'diag_bound', fields: {
      'has_couple': coupleId != null,
      'has_user': userId != null,
    });
  }

  /// Record one observation. Synchronous, allocation-light, never throws.
  ///
  /// Called from ICE callbacks that fire in bursts and from the chat send path,
  /// so it does no I/O: the timers below move data off this thread.
  static void record(
    DiagArea area,
    String name, {
    String? corr,
    Map<String, Object?> fields = const {},
  }) {
    if (!_enabled) return;
    final e = DiagEvent(
      seq: _seq++,
      // ServerClock, not DateTime.now: the whole point is that this device's
      // timeline can be laid against the partner's. Before the first clock
      // observation this is the device clock, which is what the old code used
      // for everything anyway.
      at: ServerClock.now(),
      area: area,
      name: name,
      corr: corr,
      fields: DiagRedact.fields(fields),
    );

    if (_ring.length == _ringSize) _ring.removeFirst();
    _ring.addLast(e);
    _pendingDisk.add(e);
    if (_pendingUpload.length >= _uploadQueueMax) {
      _pendingUpload.removeAt(0);
      _dropped++;
    }
    _pendingUpload.add(e);

    if (kDebugMode) debugPrint('[diag] ${e.line}');
  }

  /// Measure something whose DURATION is the evidence — a TURN fetch, an ICE
  /// connect, an ack RPC. Returns a closure that records the elapsed ms.
  ///
  /// Latency is most of what is unknown here: "the call failed" and "the call
  /// took 34 seconds to fail" point at different causes.
  static void Function({String? outcome, Map<String, Object?> fields}) span(
    DiagArea area,
    String name, {
    String? corr,
  }) {
    final sw = Stopwatch()..start();
    var done = false;
    return ({String? outcome, Map<String, Object?> fields = const {}}) {
      if (done) return;
      done = true;
      sw.stop();
      record(area, name, corr: corr, fields: {
        'ms': sw.elapsedMilliseconds,
        if (outcome != null) 'outcome': outcome,
        ...fields,
      });
    };
  }

  /// Newest last, for the viewer.
  static List<DiagEvent> get recent => _ring.toList(growable: false);

  static int get droppedCount => _dropped;

  /// How the server copy is doing, surfaced because it fails the same silent
  /// way everything else here does. The insert policy requires couple_id to
  /// equal current_user_couple_id(), so a stale binding rejects every row — and
  /// without this the first sign would be an empty table after a field test
  /// that cannot be repeated. When uploads are failing, the disk copy is the
  /// one to collect.
  static int uploadedCount = 0;
  static String? lastUploadError;

  /// Write what is pending to disk and to the server. Safe to call at any time;
  /// runs at most once concurrently.
  static Future<void> flush() async {
    if (_flushing || !_enabled) return;
    if (_pendingDisk.isEmpty && _pendingUpload.isEmpty) return;
    _flushing = true;
    try {
      await _flushDisk();
      await _flushUpload();
    } finally {
      _flushing = false;
    }
  }

  static Future<void> _flushDisk() async {
    final f = _file;
    if (f == null || _pendingDisk.isEmpty) return;
    final batch = List<DiagEvent>.from(_pendingDisk);
    try {
      // flush:true because the process may not survive to close the handle —
      // an unflushed buffer loses precisely the events that explain the crash.
      await f.writeAsString(
        '${batch.map((e) => e.toNdjson()).join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
      // Only now. Clearing before the write loses the batch on a transient
      // failure, and the batch around a transient failure is the interesting
      // one. The queue cap keeps a permanent failure (disk full) bounded.
      _pendingDisk.removeRange(0, batch.length);
      if (await f.length() > _fileMaxBytes) {
        await f.rename('${f.path}.1');
        _file = File(f.path);
      }
    } catch (e) {
      if (_pendingDisk.length > _uploadQueueMax) {
        _pendingDisk.removeRange(0, _pendingDisk.length - _uploadQueueMax);
      }
      debugPrint('[diag] disk flush failed: $e');
    }
  }

  static Future<void> _flushUpload() async {
    final couple = _coupleId, user = _userId;
    if (couple == null || user == null || _pendingUpload.isEmpty) return;
    final batch = List<DiagEvent>.from(_pendingUpload);
    try {
      await SupabaseService.client.from('diag_events').insert([
        for (final e in batch)
          {
            'couple_id': couple,
            'user_id': user,
            'session_id': sessionId,
            'seq': e.seq,
            'at': e.at.toIso8601String(),
            'area': e.area.name,
            'name': e.name,
            'corr': e.corr,
            'fields': e.fields,
          }
      ]);
      _pendingUpload.removeRange(0, batch.length);
      uploadedCount += batch.length;
      lastUploadError = null;
    } catch (e) {
      lastUploadError = e.runtimeType.toString();
      // Kept for the next attempt. The queue cap above stops this growing
      // forever when the device is offline for a long time.
      debugPrint('[diag] upload failed: $e');
    }
  }

  /// The whole in-memory window as text, for the clipboard.
  static String dump() => _ring.map((e) => e.line).join('\n');

  /// Everything on disk, including events from previous runs. This is what to
  /// read after the app was killed.
  static Future<String> readFile() async {
    final f = _file;
    if (f == null) return '';
    final parts = <String>[];
    for (final p in ['${f.path}.1', f.path]) {
      final file = File(p);
      if (await file.exists()) parts.add(await file.readAsString());
    }
    return parts.join();
  }

  static Future<void> clear() async {
    _ring.clear();
    _pendingDisk.clear();
    _pendingUpload.clear();
    _dropped = 0;
    for (final p in ['${_file?.path}.1', _file?.path]) {
      if (p == null) continue;
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  @visibleForTesting
  static void resetForTest({bool enabled = true}) {
    _ring.clear();
    _pendingDisk.clear();
    _pendingUpload.clear();
    _seq = 0;
    _dropped = 0;
    _coupleId = null;
    _userId = null;
    _file = null;
    _enabled = enabled;
  }

  @visibleForTesting
  static List<DiagEvent> get pendingUploadForTest =>
      List.unmodifiable(_pendingUpload);
}
