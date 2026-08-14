import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Bounded, cancellable work for grids of encrypted media.
///
/// The pager's single-flight guard in `media_viewer.dart` is a PAGER guard —
/// one page, one job. A grid has fifty cells building at once, and a fling from
/// memory 1 to memory 50 starts roughly forty-five jobs in `initState`, about
/// forty of which belong to cells that have already been recycled. They then
/// complete in enqueue order, so the six tiles the user is actually looking at
/// finish LAST: a second of grey on a device that already had every byte on
/// disk.
///
/// Two rules fix that, and the second is the one that is easy to get wrong:
///
///   1. Concurrency 2. Decrypt plus decode is CPU, and the target handsets have
///      two usable cores while one of them is trying to animate the scroll.
///
///   2. [_Job.isWanted] is re-read at DEQUEUE time, never captured at enqueue.
///      A job whose cell has scrolled away is dropped without running — the same
///      "re-read rather than captured" discipline the viewer already uses for
///      its neighbour precache, applied to a grid.
class MediaDecodeQueue {
  MediaDecodeQueue._();

  static const int _maxInFlight = 2;

  static final Queue<_Job> _queue = Queue<_Job>();

  /// In-flight work by id, so a duplicate request JOINS it.
  ///
  /// This used to be a Set and a duplicate resolved to null without running
  /// anything. Null is also what a dropped job returns, so the caller could not
  /// tell "somebody else is already doing this" from "nothing happened" — and
  /// the cover widget treated both as a finished load with no image, painting a
  /// blank box with no error and no retry.
  ///
  /// That was not rare. The disguise cover destroys the entire widget tree on
  /// any focus loss, so the sequence — state A enqueues, A is disposed, state B
  /// asks for the same id and is told null, A's job is then dropped as unwanted
  /// — is a routine glance at the notification shade.
  static final Map<Object, Future<Object?>> _inFlight = <Object, Future<Object?>>{};

  static int _running = 0;

  /// Runs [task] when a slot frees, unless [isWanted] has become false by then.
  ///
  /// [id] deduplicates: a cell rebuilt three times while queued enqueues once
  /// and all three await the same result. Null means the work was dropped
  /// because nobody wanted it any more — callers must treat that as "not
  /// loaded", never as "loaded nothing".
  static Future<T?> run<T>(
    Object id,
    bool Function() isWanted,
    Future<T> Function() task,
  ) {
    final existing = _inFlight[id];
    if (existing != null) return existing.then((v) => v as T?);

    final completer = Completer<Object?>();
    _inFlight[id] = completer.future;
    _queue.add(_Job(id, isWanted, () async {
      try {
        completer.complete(await task());
      } catch (e, s) {
        if (!completer.isCompleted) completer.completeError(e, s);
      }
    }, () {
      if (!completer.isCompleted) completer.complete(null);
    }));
    _pump();
    return completer.future.then((v) => v as T?);
  }

  static void _pump() {
    while (_running < _maxInFlight && _queue.isNotEmpty) {
      final job = _queue.removeFirst();
      // The id is held until the job FINISHES, not until it starts, so a cell
      // that rebuilds mid-decode joins the running job rather than enqueuing
      // the identical work again — the common case during a scroll.
      // isWanted is asked NOW, not when this was enqueued.
      if (!job.isWanted()) {
        _inFlight.remove(job.id);
        job.drop();
        continue;
      }
      _running++;
      job.run().whenComplete(() {
        _inFlight.remove(job.id);
        _running--;
        _pump();
      });
    }
  }

  /// Drops everything not yet started. Leaving a screen should not leave two
  /// dozen decrypts running for cells that no longer exist.
  static void cancelAll() {
    for (final job in _queue) {
      job.drop();
    }
    _queue.clear();
    _inFlight.clear();
  }

  @visibleForTesting
  static int get pending => _queue.length;

  @visibleForTesting
  static int get running => _running;

  @visibleForTesting
  static void resetForTest() {
    cancelAll();
    _running = 0;
  }
}

class _Job {
  _Job(this.id, this.isWanted, this.run, this.drop);
  final Object id;
  final bool Function() isWanted;
  final Future<void> Function() run;
  final void Function() drop;
}
