import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/exit_reasons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one channel a native crash, an ANR or a killed-by-the-system death has
/// into client_errors. No crash SDK ships, so if this misfiles or double-files
/// nothing else will notice.
void main() {
  late List<Map<String, Object?>> rows;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ErrorReporter.resetForTest();
    rows = [];
    ErrorReporter.insertRow = (row) async => rows.add(row);
    ExitReasons.fetchForTest = null;
  });

  tearDown(() {
    ExitReasons.fetchForTest = null;
    ErrorReporter.resetForTest();
  });

  Map<Object?, Object?> exit(int reason, int ts, {String? trace}) => {
        'reason': reason,
        'description': 'reason $reason',
        'timestamp': ts,
        'importance': 100,
        'trace': trace,
      };

  test('the first run learns the record and files nothing', () async {
    // A crash of the PREVIOUS build must never be filed under this build's
    // number, and this launch is the first that can read the record.
    ExitReasons.fetchForTest = () async => [exit(4, 1000), exit(6, 2000)];
    expect(await ExitReasons.report(), 0);
    expect(rows, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('exit_reasons_seen_until'), 2000,
        reason: 'the watermark is the newest death, not now',);
  });

  test('a death newer than the watermark is filed once, by kind', () async {
    SharedPreferences.setMockInitialValues({'exit_reasons_seen_until': 2000});
    ExitReasons.fetchForTest = () async => [
          exit(4, 1000), // old: below the watermark
          exit(5, 3000, trace: 'signal 11 (SIGSEGV)\n#00 pc libjingle'),
          exit(6, 4000),
        ];
    expect(await ExitReasons.report(), 2);
    expect(rows.map((r) => r['kind']), ['exit-native', 'exit-anr']);
    expect(rows.every((r) => r['error_type'] == 'ProcessExit'), isTrue);
    expect(rows.every((r) => r['build'] == ReleaseGate.buildNumber), isTrue);
    expect(rows.first['stack'], contains('SIGSEGV'),
        reason: 'the OS trace rides the stack column',);
    expect(rows.last['stack'], contains('reason 6'),
        reason: 'no trace: the description and the instant stand in',);
    // Run again: nothing new, nothing filed twice.
    expect(await ExitReasons.report(), 0);
    expect(rows.length, 2);
  });

  test('deaths that are the OS doing its job are not defects', () async {
    SharedPreferences.setMockInitialValues({'exit_reasons_seen_until': 1});
    ExitReasons.fetchForTest = () async => [
          exit(3, 10), // low memory
          exit(10, 20), // user requested
          exit(16, 30), // package updated
        ];
    expect(await ExitReasons.report(), 0);
    expect(rows, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('exit_reasons_seen_until'), 30,
        reason: 'seen, even if not filed',);
  });

  test('an unavailable record is a debug line, not a startup failure',
      () async {
    ExitReasons.fetchForTest = () async => throw StateError('no channel');
    expect(await ExitReasons.report(), 0);
    expect(rows, isEmpty);
  });

  test('read before the client exists, the row waits for the flush', () async {
    // main() reads the record ahead of SupabaseService.init, so the insert
    // cannot land; the buffer carries it to flushBuffered below the gate.
    SharedPreferences.setMockInitialValues({'exit_reasons_seen_until': 1});
    ErrorReporter.insertRow = (_) async => throw StateError('no client yet');
    ExitReasons.fetchForTest = () async => [exit(4, 5)];
    expect(await ExitReasons.report(), 1);
    await pumpEventQueue();
    expect(rows, isEmpty);
    // The launch reaches the gate line: the client exists and a session holds.
    ErrorReporter.insertRow = (row) async => rows.add(row);
    ErrorReporter.hasSession = () => true;
    await ErrorReporter.flushBuffered();
    expect(rows.map((r) => r['kind']), ['exit-crash']);
    expect(rows.single['stack'], 'reason 4 @5');
  });
}
