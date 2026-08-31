import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/diag/diag.dart';

/// The ritual's note arrived unreadable on the partner's phone (BRAIN §232)
/// and the report said only `SecretBoxAuthenticationError` — which cannot tell
/// "this phone has no couple key" from "this phone derived against a DIFFERENT
/// partner public key", and those want opposite repairs.
///
/// These pin the two things that make the next occurrence conclusive: the
/// facts survive redaction, and they survive the server's 64-char ceiling on
/// `detail` — a diagnostic that gets truncated where it matters is a
/// diagnostic nobody can read.
void main() {
  setUp(ErrorReporter.resetForTest);

  test('the row carries the key facts, inside the 64-char ceiling', () async {
    final rows = <Map<String, Object?>>[];
    ErrorReporter.insertRow = (row) async => rows.add(row);
    ErrorReporter.hasSession = () => true;

    ErrorReporter.report(
      NoteUnreadable(
        keyReady: true,
        derivedFrom: 'akfB+ebQ',
        ringSize: 0,
        cause: 'SecretBoxAuthenticationError',
      ),
      StackTrace.current,
      kind: 'unlink',
    );
    await Future<void>.delayed(Duration.zero);

    expect(rows, hasLength(1));
    expect(rows.single['error_type'], 'NoteUnreadable');
    final detail = rows.single['detail']! as String;
    expect(detail, 'from=akfB+ebQ key=1 ring=0 SecretBoxAuthenticationError');
    expect(detail.length, lessThanOrEqualTo(64));
  });

  test('the worst case still fits, and keeps the deciding facts', () async {
    final rows = <Map<String, Object?>>[];
    ErrorReporter.insertRow = (row) async => rows.add(row);
    ErrorReporter.hasSession = () => true;

    ErrorReporter.report(
      NoteUnreadable(
        keyReady: false,
        derivedFrom: 'none',
        ringSize: 99,
        cause: 'SomeVeryLongCryptographyFailureClassName',
      ),
      StackTrace.current,
      kind: 'unlink',
    );
    await Future<void>.delayed(Duration.zero);

    final detail = rows.single['detail']! as String;
    expect(detail.length, lessThanOrEqualTo(64));
    // Truncation may eat the class name; it may never eat the answer.
    expect(detail, startsWith('from=none key=0 ring=99'));
  });
}
