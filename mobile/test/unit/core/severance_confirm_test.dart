import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Remove-partner was the most consequential action in the app and had the
/// weakest confirmation of any of them: a bare AlertDialog, one tap, no typed
/// confirmation, no hold — while deleting an account demanded a typed DELETE.
/// Its copy was also wrong twice: the private vault is derived from the
/// account's own seed and was never at risk, and "this cannot be undone"
/// contradicted the app's own FAQ two taps away.
///
/// These pin the replacement, and one thing about it that is easy to add back
/// by accident and must never exist: an undo affordance.
void main() {
  String read(String path) => File(path).readAsStringSync();

  /// Whole-line comments stripped. Without this these checks match the
  /// comments that EXPLAIN the rule — "there must never be a SnackBarAction
  /// here" contains the very string it forbids — and the test passes or fails
  /// on prose rather than on code.
  String code(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  late String settings;
  late String sheet;

  setUpAll(() {
    settings = read('lib/features/settings/settings_screen.dart');
    sheet = code(read('lib/features/safety/severance_sheet.dart'));
  });

  test('the old dialog and its false copy are gone', () {
    expect(settings.contains('Yes, disconnect'), isFalse);
    expect(settings.contains('Disconnect from '), isFalse);
    // The account-deletion dialog keeps "This cannot be undone", where it is
    // true, so this is scoped to the unpair handler rather than the file.
    final start = settings.indexOf('Future<void> _removePartner(');
    final end = settings.indexOf('Future<void> _toggleModestMode(');
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final region = settings.substring(start, end);
    expect(region.contains('This cannot be undone'), isFalse);
    expect(region.contains('are preserved'), isFalse);
  });

  test('remove-partner routes through the safety sheet', () {
    expect(settings.contains('showSeveranceSheet('), isTrue);
  });

  test('enforcement runs before the local wipe, and the wipe is guaranteed',
      () {
    final start = settings.indexOf('Future<void> _endConnection()');
    final end = settings.indexOf('Future<void> _toggleModestMode(');
    expect(start, greaterThan(-1), reason: '_endConnection has gone');
    final region = settings.substring(start, end);
    final leave = region.indexOf('leaveCouple()');
    final wipe = region.indexOf('endCouple(');
    final reload = region.indexOf('loadProfile()');
    expect(leave, greaterThan(-1));
    expect(wipe, greaterThan(leave),
        reason: 'the couple must be dissolved server-side before the wipe');
    expect(reload, greaterThan(wipe),
        reason: 'loadProfile nulls the couple id the wipe needs');
    expect(region.contains('} finally {'), isTrue,
        reason: 'a teardown that only runs when nothing threw skips exactly '
            'the cases it exists for');
  });

  test('the severance sheet offers no undo and announces nothing', () {
    // An "Undo" chip on screen for four seconds after someone leaves is
    // readable by whoever is standing next to them and tappable by whoever
    // takes the phone. There is no undo-snackbar pattern anywhere in this
    // codebase and this is not the place to introduce one.
    expect(sheet.contains('SnackBarAction'), isFalse);
    // Nothing about ending a connection may notify the other person.
    expect(sheet.contains('notify'), isFalse);
    expect(sheet.contains('FcmService'), isFalse);
  });

  test('the destructive rung is drawn unconditionally', () {
    // It is never behind a heuristic, a flag or a delay. Whatever else the
    // sheet learns to do, this row is always present.
    expect(sheet.contains("'End the connection'"), isTrue);
    expect(sheet.contains('HoldToConfirm('), isTrue);
    // And account deletion is never buried behind ending a connection.
    expect(sheet.contains("'Delete your account'"), isTrue);
  });
}
