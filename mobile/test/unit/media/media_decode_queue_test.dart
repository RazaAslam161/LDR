import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/media/media_decode_queue.dart';

/// The blank cover in Memory Threads was this queue, not the crypto: a second
/// request for an id already in flight was answered with null WITHOUT running
/// anything, and null is also what a dropped job returns. The caller could not
/// tell the two apart, so it treated "somebody else is loading this" as
/// "finished, nothing to show" and painted an empty box for good.
void main() {
  setUp(MediaDecodeQueue.resetForTest);

  test('a duplicate request joins the in-flight job instead of getting null',
      () async {
    var runs = 0;
    final gate = Completer<void>();

    final first = MediaDecodeQueue.run<String>('same', () => true, () async {
      runs++;
      await gate.future;
      return 'loaded';
    });
    final second =
        MediaDecodeQueue.run<String>('same', () => true, () async {
      runs++;
      return 'other';
    });

    gate.complete();
    expect(await first, 'loaded');
    // The whole defect: this used to be null.
    expect(await second, 'loaded');
    expect(runs, 1, reason: 'the work should happen exactly once');
  });

  test('a job nobody wants any more resolves null, not a value', () async {
    final result =
        await MediaDecodeQueue.run<String>('gone', () => false, () async {
      fail('an unwanted job must not run');
    });
    expect(result, isNull);
  });

  test('an id is released after a drop, so the next state can load it',
      () async {
    // State A enqueues and is then disposed — the disguise cover tears the tree
    // down on any focus loss, so this is routine. State B must still be able to
    // load the same object.
    final dropped =
        await MediaDecodeQueue.run<String>('obj', () => false, () async {
      fail('unwanted');
    });
    expect(dropped, isNull);

    final reloaded =
        await MediaDecodeQueue.run<String>('obj', () => true, () async => 'ok');
    expect(reloaded, 'ok',
        reason: 'the id must not stay locked after its job was dropped');
  });

  test('an error reaches the caller rather than becoming a silent null',
      () async {
    await expectLater(
      MediaDecodeQueue.run<String>('boom', () => true, () async {
        throw StateError('decrypt failed');
      }),
      throwsStateError,
    );
  });

  test('two different ids both run', () async {
    final a = MediaDecodeQueue.run<int>('a', () => true, () async => 1);
    final b = MediaDecodeQueue.run<int>('b', () => true, () async => 2);
    expect(await a, 1);
    expect(await b, 2);
  });

  test('concurrency stays bounded at two', () async {
    var peak = 0;
    var live = 0;
    final gate = Completer<void>();

    final jobs = List.generate(
      6,
      (i) => MediaDecodeQueue.run<void>('job$i', () => true, () async {
        live++;
        if (live > peak) peak = live;
        await gate.future;
        live--;
      }),
    );

    await Future<void>.delayed(Duration.zero);
    expect(peak, lessThanOrEqualTo(2));
    gate.complete();
    await Future.wait(jobs);
  });
}
