import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "I have held that button hundreds of times. I have never once known
/// whether one of them landed." The answer was written (acknowledged_at) and
/// never read: the sender inserted without asking for the id, subscribed to
/// INSERTs only, and the push path showed an overlay for any id it was handed.
String _fn(String src, String head) {
  final at = src.indexOf(head);
  expect(at, greaterThan(-1), reason: '$head not found');
  // The method's own closing brace — two spaces, a brace, a line end — not
  // the `  }) {` that closes a multi-line parameter list.
  return src.substring(at, src.indexOf(RegExp(r'\n  \}\r?\n'), at));
}

void main() {
  final repo = File('lib/features/reach/reach_repository.dart').readAsStringSync();
  final shell = File('lib/features/shell/app_shell.dart').readAsStringSync();
  final button = File('lib/features/reach/reach_button.dart').readAsStringSync();
  final overlay =
      File('lib/features/reach/reach_overlay_screen.dart').readAsStringSync();

  test('the sender holds the id of what it sent', () {
    final reach = _fn(repo, 'static Future<String?> reach(');
    expect(reach, contains(".select('id')"));
    expect(button, contains('_lastReachId = await ReachRepository.reach('));
  });

  test('the acknowledgement rides the UPDATE rail back to the sender', () {
    final sub = _fn(repo, 'static RealtimeChannel subscribe(');
    expect(sub, contains('PostgresChangeEvent.update'));
    expect(shell, contains('onAck: _onReachAck'));
    final ack = _fn(shell, 'void _onReachAck(ReachEvent e) {');
    expect(ack, contains('reachAcknowledged.value = e.id'));
    expect(button, contains('reachAcknowledged.addListener(_onAck)'));
    expect(button, contains('reachAcknowledged.removeListener(_onAck)'));
    expect(button, contains('is here'));
  });

  test('the push path refuses a reach that has expired', () {
    final pending = _fn(shell, 'Future<void> _onPendingReach() async {');
    expect(pending.indexOf('isActive'), lessThan(pending.indexOf('_showReach(')),
        reason: 'the expiry check must precede the overlay',);
    expect(pending, contains("kind: 'reach-tap'"));
  });

  test("a failed 'I'm here' is reported, not swallowed", () {
    final ack = _fn(overlay, 'Future<void> _acknowledge() async {');
    expect(ack, isNot(contains('catch (_)')));
    expect(ack, contains("kind: 'reach-ack'"));
  });

  test('the migration narrows the update grant to the one column', () {
    final sql = File(
      '../supabase/migrations/20260906140000_the_ack_is_the_only_column_a_client_may_update_on_reach_events.sql',
    ).readAsStringSync();
    final revoke = sql.indexOf('revoke update on public.reach_events from authenticated, anon;');
    final grant = sql.indexOf('grant update (acknowledged_at) on public.reach_events to authenticated;');
    expect(revoke, greaterThan(-1));
    expect(grant, greaterThan(revoke), reason: 'table revoke, then the column grant');
    expect(sql, contains('ROLLBACK'));
  });
}
