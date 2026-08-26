import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/safety/severance_state.dart';

/// The state machine the reconnect sheet draws from.
///
/// Worth real tests rather than source checks: every branch is reachable
/// without a database, and the combinations are exactly where a "who asked,
/// whose turn is it" model goes wrong.
void main() {
  Map<String, dynamic> row({
    Object? requestIsMine,
    Object? awaitingMe,
    bool confirmed = false,
    bool declined = false,
  }) =>
      {
        'couple_id': '11111111-1111-4111-8111-111111111111',
        'dissolved_at': '2026-08-23T00:00:00Z',
        'expires_at': '2026-09-22T00:00:00Z',
        'request_kind': requestIsMine == null ? null : 'reunite',
        'request_is_mine': requestIsMine,
        'awaiting_me': awaitingMe,
        'confirmed': confirmed,
        'declined': declined,
      };

  tearDown(SeveranceState.reset);

  test('a null answer shows nothing', () {
    SeveranceState.applyRow(null);
    expect(SeveranceState.held.value, isNull);
  });

  test('nobody has asked: this account may ask, and is not prompted', () {
    SeveranceState.applyRow(row());
    final h = SeveranceState.held.value!;
    expect(h.canAsk, isTrue);
    expect(h.waitingOnThem, isFalse);
    expect(h.awaitingMe, isNull, reason: 'null must not read as a prompt');
  });

  test('my own open ask waits on them and does not prompt me', () {
    SeveranceState.applyRow(row(requestIsMine: true, awaitingMe: false));
    final h = SeveranceState.held.value!;
    expect(h.waitingOnThem, isTrue);
    expect(h.awaitingMe, isFalse);
    expect(h.canAsk, isFalse, reason: 'one open ask at a time');
  });

  test('their open ask prompts me and is not mine to withdraw', () {
    SeveranceState.applyRow(row(requestIsMine: false, awaitingMe: true));
    final h = SeveranceState.held.value!;
    expect(h.awaitingMe, isTrue);
    expect(h.waitingOnThem, isFalse);
  });

  test('being declined is final for the one who asked', () {
    // The server enforces this; the client must not draw an "ask again"
    // button that is going to be refused.
    SeveranceState.applyRow(
        row(requestIsMine: true, awaitingMe: false, declined: true),);
    expect(SeveranceState.held.value!.canAsk, isFalse);
  });

  test('declining someone leaves me free to ask myself', () {
    // Changing your mind about your OWN decision is not badgering, and the
    // server allows it, so the client must offer it.
    SeveranceState.applyRow(
        row(requestIsMine: false, awaitingMe: false, declined: true),);
    expect(SeveranceState.held.value!.canAsk, isTrue);
  });

  test('a state that has gone stale past its window shows nothing', () {
    // The server will not return a state past the window, so this only fires
    // on a value that aged in memory — but a control drawn from it would do
    // nothing when tapped, which is the case this whole design refuses.
    SeveranceState.applyRow({
      'couple_id': '11111111-1111-4111-8111-111111111111',
      'dissolved_at': '2020-01-01T00:00:00Z',
      'expires_at': '2020-01-31T00:00:00Z',
      'request_kind': null,
      'request_is_mine': null,
      'awaiting_me': null,
      'confirmed': false,
      'declined': false,
    });
    expect(SeveranceState.held.value!.expired, isTrue);
  });

  test('reset clears state that would otherwise outlive the account', () {
    SeveranceState.applyRow(row(requestIsMine: true, awaitingMe: false));
    expect(SeveranceState.held.value, isNotNull);
    SeveranceState.reset();
    expect(SeveranceState.held.value, isNull,
        reason: 'the next person to sign in on this handset must not be told '
            'about somebody else’s breakup',);
  });
}
