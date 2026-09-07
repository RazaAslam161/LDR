import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/presence_service.dart';

/// `humanPresent` was an alias of the disguise cover. The app lock and the
/// stealth scrim are Stack siblings over a live router and never lower it, and
/// on a build whose cover is `none` the flag was set true once and never fell —
/// so the one refusal that keeps a push-woken process from claiming a person
/// was there could never fire. These pin the derivation and its wiring.
void main() {
  test('a person is looking only when every gate is open', () {
    bool d({bool realApp = true, bool locked = false, bool stealth = false,
        bool foregrounded = true,}) =>
        PresenceService.derivePresence(
          realApp: realApp,
          locked: locked,
          stealth: stealth,
          foregrounded: foregrounded,
        );
    expect(d(), isTrue);
    expect(d(realApp: false), isFalse, reason: 'the cover is up');
    expect(d(locked: true), isFalse, reason: 'the app lock is up');
    expect(d(stealth: true), isFalse, reason: 'the stealth scrim is up');
    expect(d(foregrounded: false), isFalse, reason: 'the process is behind');
  });

  test('the flag is a notifier, and the getter reads it', () {
    PresenceService.humanPresent = false;
    var fired = 0;
    void tick() => fired++;
    PresenceService.present.addListener(tick);
    PresenceService.humanPresent = true;
    expect(PresenceService.humanPresent, isTrue);
    expect(fired, 1);
    PresenceService.present.removeListener(tick);
    PresenceService.humanPresent = false;
  });

  test('main.dart derives it from all four inputs and re-derives on each',
      () {
    final main = File('lib/main.dart').readAsStringSync();
    final at = main.indexOf('void _trackHumanPresence() {');
    expect(at, greaterThan(0));
    final body = main.substring(at, main.indexOf('\n  }', at));
    for (final input in [
      'MilesApp.showRealApp.value',
      'AppLock.locked.value',
      'stealthActive.value',
      'lifecycleState',
    ]) {
      expect(body, contains(input), reason: '$input must feed presence');
    }
    expect(main, contains('AppLock.locked.addListener(_trackHumanPresence)'));
    expect(main, contains('stealthActive.addListener(_trackHumanPresence)'));
    final lifecycle = main.indexOf('void didChangeAppLifecycleState(');
    expect(main.substring(lifecycle, lifecycle + 400),
        contains('_trackHumanPresence()'),);
  });

  test('the heartbeat beats on the person, not on the cover', () {
    final main = File('lib/main.dart').readAsStringSync();
    final at = main.indexOf('void beat() {');
    expect(at, greaterThan(0));
    final body = main.substring(at, main.indexOf('\n    }', at));
    expect(body, contains('PresenceService.humanPresent'));
    expect(body, isNot(contains('showRealApp.value')));
  });

  test('every app-activity writer is demoted when nobody is looking', () {
    final svc =
        File('lib/core/services/presence_service.dart').readAsStringSync();
    final at = svc.indexOf('static Future<bool> _upsert(');
    expect(at, greaterThan(0));
    final body = svc.substring(at, at + 2400);
    expect(body, contains('isAppActivity && humanPresent'));
    expect(body, contains("if (activity) 'app_last_active_at'"));
  });
}
