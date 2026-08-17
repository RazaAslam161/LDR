import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The report that matters most is the one a launch crash produces — and that
/// was exactly the report [ErrorReporter] used to drop: thrown before
/// SupabaseService.init, or signed out, or offline, the insert failed and the
/// catch discarded the row. A build that dies on launch for every user looked
/// like a build nobody opened, precisely because everybody opened it.
///
/// These cases pin the buffer that fixed it: bounded so a crash loop cannot
/// grow the disk, oldest dropped first, cleared by a flush that lands,
/// retained by one that does not, and finite tries so a row the server will
/// never accept cannot ride the buffer forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = 'client_errors_pending';

  String entry(Map<String, Object?> row, {int tries = 0}) =>
      jsonEncode({'tries': tries, 'row': row});

  Map<String, Object?> rowNamed(String stamp) => {
        'build': 1,
        'kind': 'flutter',
        'error_type': 'StateError',
        'stack': '#0 $stamp (x.dart:1)',
      };

  String stackOf(String e) =>
      ((jsonDecode(e) as Map<String, dynamic>)['row']
          as Map<String, dynamic>)['stack'] as String;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ErrorReporter.resetForTest();
  });

  test('a report thrown before SupabaseService.init is buffered, not lost',
      () async {
    // No seams overridden: the real insert path reads SupabaseService.client,
    // which in this process — exactly as in a launch that died early — was
    // never assigned.
    ErrorReporter.report(
      StateError('plaintext that must never come to rest'),
      StackTrace.fromString('#0 boot (main.dart:1)'),
      kind: 'flutter',
    );
    await pumpEventQueue();

    final pending =
        (await SharedPreferences.getInstance()).getStringList(key)!;
    expect(pending, hasLength(1));
    final decoded = jsonDecode(pending.single) as Map<String, dynamic>;
    expect(decoded['tries'], 0);
    final row = decoded['row'] as Map<String, dynamic>;
    expect(row['error_type'], 'StateError');
    expect(row['kind'], 'flutter');
    // Redaction happened BEFORE persisting: the message is discarded when the
    // row is built, so it never touches the disk of an E2EE app.
    expect(pending.single.contains('plaintext'), isFalse);
  });

  test('the buffer holds 20 rows, oldest dropped first', () async {
    // Five runs of the five-per-run cap. Each run's reports fail to send and
    // fall through to the buffer, which is the only thing that outlives runs.
    for (var run = 0; run < 5; run++) {
      ErrorReporter.resetForTest();
      ErrorReporter.insertRow = (_) async => throw StateError('offline');
      for (var i = 0; i < 5; i++) {
        final n = run * 5 + i;
        ErrorReporter.report(
          StateError('e$n'),
          StackTrace.fromString('#0 f$n (x.dart:$n)'),
          kind: 'flutter',
        );
      }
      await pumpEventQueue();
    }

    final pending =
        (await SharedPreferences.getInstance()).getStringList(key)!;
    expect(pending, hasLength(20));
    expect(stackOf(pending.first), contains('f5 '),
        reason: 'f0..f4 are the oldest and must be the ones dropped',);
    expect(stackOf(pending.last), contains('f24 '));
  });

  test('a flush that lands delivers oldest first and clears the buffer',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: [entry(rowNamed('first')), entry(rowNamed('second'))],
    });
    final delivered = <String>[];
    ErrorReporter.hasSession = () => true;
    ErrorReporter.insertRow =
        (row) async => delivered.add(row['stack']! as String);

    await ErrorReporter.flushBuffered();

    expect(delivered, hasLength(2));
    expect(delivered.first, contains('first'));
    expect(delivered.last, contains('second'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(key), anyOf(isNull, isEmpty));
  });

  test('a flush that fails re-persists the rows rather than dropping them',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: [entry(rowNamed('kept'))],
    });
    ErrorReporter.hasSession = () => true;
    ErrorReporter.insertRow = (_) async => throw StateError('offline');

    await ErrorReporter.flushBuffered();

    final pending =
        (await SharedPreferences.getInstance()).getStringList(key)!;
    expect(pending, hasLength(1));
    final decoded = jsonDecode(pending.single) as Map<String, dynamic>;
    expect(decoded['tries'], 1,
        reason: 'the attempt must be marked, or a poison row retries forever',);
    expect(stackOf(pending.single), contains('kept'));
  });

  test('a row the server never accepts is dropped on its third strike',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: [entry(rowNamed('poison'), tries: 2)],
    });
    ErrorReporter.hasSession = () => true;
    ErrorReporter.insertRow = (_) async => throw StateError('check violation');

    await ErrorReporter.flushBuffered();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(key), anyOf(isNull, isEmpty));
  });

  test('no session leaves the buffer alone and burns no tries', () async {
    // A crash during onboarding is buffered before anyone is signed in. The
    // rows must wait for a launch that CAN deliver, not spend their three
    // tries failing against a table only `authenticated` may write.
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: [entry(rowNamed('waiting'))],
    });
    ErrorReporter.hasSession = () => false;
    ErrorReporter.insertRow =
        (_) async => fail('nothing may be sent without a session');

    await ErrorReporter.flushBuffered();

    final pending =
        (await SharedPreferences.getInstance()).getStringList(key)!;
    expect(pending, hasLength(1));
    expect(
      (jsonDecode(pending.single) as Map<String, dynamic>)['tries'],
      0,
    );
  });

  test('a report buffered DURING the flush survives the write-back', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: [entry(rowNamed('retried'))],
    });
    ErrorReporter.hasSession = () => true;
    ErrorReporter.insertRow = (_) async {
      // What a live report failing mid-flush does: appends to the same list
      // the flush is about to write its survivors back into. An overwrite
      // here would be the flush eating a fresh crash report.
      final prefs = await SharedPreferences.getInstance();
      final live = prefs.getStringList(key) ?? <String>[];
      live.add(entry(rowNamed('live')));
      await prefs.setStringList(key, live);
      throw StateError('offline');
    };

    await ErrorReporter.flushBuffered();

    final pending =
        (await SharedPreferences.getInstance()).getStringList(key)!;
    expect(pending, hasLength(2));
    expect(stackOf(pending.first), contains('retried'),
        reason: 'the retried row is older and stays in front',);
    expect(stackOf(pending.last), contains('live'));
  });

  test('a corrupt entry is dropped without taking the flush down', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      key: ['not json', entry(rowNamed('good'))],
    });
    final delivered = <String>[];
    ErrorReporter.hasSession = () => true;
    ErrorReporter.insertRow =
        (row) async => delivered.add(row['stack']! as String);

    await ErrorReporter.flushBuffered();

    expect(delivered, hasLength(1));
    expect(delivered.single, contains('good'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(key), anyOf(isNull, isEmpty));
  });
}
