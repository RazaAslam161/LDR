import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';

/// The sink runs inside ICE callbacks and the chat send path, so the properties
/// that matter are the boring ones: it never throws, never blocks, never grows
/// without bound, and never loses the ORDER of two events in the same
/// millisecond. A diagnostic that can break a call is not a diagnostic.
void main() {
  setUp(Diag.resetForTest);

  test('records nothing at all when switched off', () {
    Diag.resetForTest(enabled: false);
    Diag.record(DiagArea.call, 'offer_sent');
    expect(Diag.recent, isEmpty);
    expect(Diag.pendingUploadForTest, isEmpty);
  });

  test('seq is monotonic, so a burst inside one millisecond keeps its order', () {
    // ICE candidates arrive in bursts. Sorting the trace by timestamp alone
    // reorders them, and their order is the evidence.
    for (var i = 0; i < 50; i++) {
      Diag.record(DiagArea.call, 'ice_local_candidate');
    }
    final seqs = Diag.recent.map((e) => e.seq).toList();
    expect(seqs, List.generate(50, (i) => i));
  });

  test('the ring is bounded and keeps the NEWEST events', () {
    // A call that fails after twenty minutes is explained by the last hundred
    // events, never the first.
    for (var i = 0; i < 1200; i++) {
      Diag.record(DiagArea.app, 'tick', fields: {'i': i});
    }
    expect(Diag.recent.length, 1000);
    expect(Diag.recent.first.fields['i'], 200);
    expect(Diag.recent.last.fields['i'], 1199);
  });

  test('the upload queue drops the OLDEST and counts what it dropped', () {
    // An offline phone must not grow a queue until it crashes days later. The
    // count is what stops a truncated trace from reading as a complete one.
    for (var i = 0; i < 600; i++) {
      Diag.record(DiagArea.presence, 'heartbeat', fields: {'i': i});
    }
    expect(Diag.pendingUploadForTest.length, 500);
    expect(Diag.droppedCount, 100);
    expect(Diag.pendingUploadForTest.first.fields['i'], 100);
  });

  test('fields are redacted on the way in, not on the way out', () {
    // The ring is copied to the clipboard and the file is read after a crash.
    // Redacting at the sink means no later reader can leak what the sink let in.
    Diag.record(DiagArea.receipt, 'send', fields: {
      'seq': 41,
      'body': 'are you still awake? I keep thinking about what you said',
    },);
    final e = Diag.recent.single;
    expect(e.fields['seq'], 41);
    expect(e.fields['body'], DiagRedact.redacted);
    expect(e.toNdjson().contains('awake'), isFalse);
    expect(e.line.contains('awake'), isFalse);
  });

  group('span', () {
    test('records elapsed milliseconds and the outcome', () {
      final end = Diag.span(DiagArea.call, 'turn_fetch');
      end(outcome: 'ok', fields: {'ice_servers': 2});
      final e = Diag.recent.single;
      expect(e.name, 'turn_fetch');
      expect(e.fields['ms'], isA<int>());
      expect(e.fields['outcome'], 'ok');
      expect(e.fields['ice_servers'], 2);
    });

    test('is idempotent', () {
      // Both the success path and the error path end a span, and on some paths
      // both run. A duplicate makes a retried fetch look like two fetches.
      final end = Diag.span(DiagArea.call, 'turn_fetch');
      end(outcome: 'ok');
      end(outcome: 'failed');
      expect(Diag.recent.length, 1);
      expect(Diag.recent.single.fields['outcome'], 'ok');
    });
  });

  test('corr is what joins two devices, and survives to the wire', () {
    Diag.record(DiagArea.call, 'offer_sent', corr: 'call-abc', fields: {'v': 1});
    final e = Diag.recent.single;
    expect(e.corr, 'call-abc');
    expect(e.toNdjson(), contains('call-abc'));
    expect(e.line, contains('[call-abc]'));
  });

  test('a flush with no couple bound keeps events queued rather than losing them',
      () async {
    // Events recorded before the session resolves are the cold-start ordering
    // evidence. Dropping them would remove exactly the window being hunted.
    Diag.record(DiagArea.app, 'early');
    await Diag.flush();
    expect(Diag.pendingUploadForTest.length, 1);
  });
}
