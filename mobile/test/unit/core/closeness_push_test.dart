import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// notify_closeness (20260820030000) has posted kind 'closeness' to
/// reach-notify since 2026-08-20, and every shipped client's background
/// allowlist dropped it before any branch ran — the third time a server kind
/// shipped without its client half (msg_sync and memory were the first two).
/// Naming it in the list alone would have been worse: an admitted kind with no
/// branch falls through to the max-importance Reach alert.
String _code(String s) => s
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  final background =
      _code(File('lib/core/services/reach_notifications.dart').readAsStringSync());
  final foreground =
      _code(File('lib/core/services/fcm_service.dart').readAsStringSync());
  final fn = File('../supabase/functions/reach-notify/index.ts').readAsStringSync();

  test('the background handler admits closeness AND has a branch for it', () {
    expect(background, contains("type != 'closeness'"));
    final branch = background.indexOf("if (type == 'closeness') {");
    final fallthrough = background.indexOf('await showReachNotification(');
    expect(branch, greaterThan(-1));
    expect(branch, lessThan(fallthrough),
        reason: 'the branch must sit above the Reach fallthrough',);
    expect(background, contains('Future<void> showClosenessNotification('));
    expect(background, contains("payload: 'closeness|"));
  });

  test('the foreground handler and the tap router never route it to Reach', () {
    final onForeground = foreground.indexOf('static void _onForeground(');
    final onOpened = foreground.indexOf('static void _onOpenedApp(');
    final route = foreground.indexOf('static void routeFromPayload(');
    for (final start in [onForeground, onOpened]) {
      expect(start, greaterThan(-1));
      final body = foreground.substring(start, foreground.indexOf('\n  }', start));
      expect(body.indexOf("if (type == 'closeness') return;"),
          lessThan(body.indexOf("if (type != 'reach') return;")),);
    }
    final router = foreground.substring(route, foreground.indexOf('\n  }', route));
    expect(router, contains("if (tag == 'closeness') return;"));
  });

  test('reach-notify names the kind and gives it a shelf life', () {
    expect(fn, contains('| "closeness"'));
    final ttl = fn.substring(fn.indexOf('const ttlSec = kind ==='));
    expect(ttl.substring(0, 500), contains('kind === "closeness"'));
  });
}
