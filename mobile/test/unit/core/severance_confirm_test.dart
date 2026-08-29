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
    final end = settings.indexOf('Future<void> _setCloserConsent(');
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
    final end = settings.indexOf('Future<void> _setCloserConsent(');
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

  test('an ending is drawn unconditionally, in BOTH branches', () {
    // The law is that a way out is never behind a heuristic, a flag or a
    // delay. The sheet now has two shapes — with a partner and without — so
    // the law is checked on both: whichever branch renders, exactly one
    // ending row renders with it.
    expect(sheet.contains("'End the connection'"), isTrue,
        reason: 'the ceremony row is the exit when there IS a partner',);
    expect(sheet.contains("'Leave this connection'"), isTrue,
        reason: 'a couple of one must still have an exit, or the sheet is a '
            'dead end for the person already alone in it',);
    // HoldToConfirm is deliberately NOT asserted any more: it belonged to the
    // immediate exit, which the owner removed on 2026-08-29. Asserting it
    // would pin a control this sheet must no longer have.
    expect(sheet.contains('HoldToConfirm('), isFalse,
        reason: 'the hold gesture went with the immediate exit',);
    // And account deletion is never buried behind ending a connection.
    expect(sheet.contains("'Delete your account'"), isTrue);
  });

  test('the ceremony is the ONLY way out; there is no immediate exit', () {
    // Owner removed "Leave right now" on 2026-08-29. Two endings with two
    // different rules — one of them behind a proof-of-owner prompt that said
    // nothing at all when it failed — is what this sheet no longer offers.
    expect(sheet.contains('unlinkStarted'), isTrue);
    expect(sheet.contains('onStartCeremony'), isTrue);
    expect(sheet.contains("'Leave right now'"), isFalse,
        reason: 'the immediate exit was removed; do not reintroduce it',);
    expect(sheet.contains('confirmIdentity'), isFalse,
        reason: 'the identity gate existed only for that exit',);
    // The pause offramp bubbles as the pause outcome — a rage-quit that
    // actually wanted distance must find distance on the way.
    expect(sheet.contains("'Pause instead'"), isTrue);
  });

  test('a couple of ONE is offered only what the server will accept', () {
    // mute_partner raises 'no partner' and unlink_start has nobody to tell,
    // so both rows are withheld when there is no partner — that pair of dead
    // controls is what "I pressed 1 hour and nothing happened" was.
    expect(sheet.contains('required bool hasPartner'), isTrue);
    expect(sheet.contains('if (hasPartner)'), isTrue,
        reason: 'the partner-only rows must be conditional',);
    expect(sheet.contains("'Leave this connection'"), isTrue,
        reason: 'an empty connection still needs an exit from this screen',);
    expect(settings.contains('sessionProvider).partner != null'), isTrue,
        reason: 'a couple of one HAS a couple; the partner is the real test',);
  });

  test('settings wires the ceremony and the empty-connection exit', () {
    expect(settings.contains('onStartCeremony: _startUnlink'), isTrue);
    expect(settings.contains("context.push('/unlink')"), isTrue,
        reason: 'beginning the ceremony lands the initiator on its screen',);
    expect(
        settings.contains('confirmIdentity: _confirmEmergencyIdentity'),
        isFalse,
        reason: 'the identity gate went with the immediate exit',);
    // SeveranceOutcome.ended is no longer a no-op: it is the couple-of-one
    // exit, and it must still run leaveCouple in the caller's context so the
    // server dissolve precedes the local wipe.
    expect(settings.contains('await _endConnection();'), isTrue,
        reason: 'the ended outcome must actually leave the couple',);
  });
}
