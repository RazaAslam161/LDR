import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/realtime/presence_route_observer.dart';
import 'package:miles/core/services/presence_service.dart';

/// What one identity leaves behind for the next one on the same handset.
///
/// Every holder below is process-scoped and the process does not restart on
/// sign-out, so each of them answered for the wrong person until something
/// emptied it: the observer's dedupe, the last liveness hint off the socket,
/// and the device's own binding to a couple.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Route<dynamic> page(String? name) => MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => const SizedBox.shrink(),
      );

  test('a room held under the old identity is not replayed into the new one',
      () {
    // With no couple the observer HOLDS the room rather than dropping it, and
    // replays it the moment a couple exists. That is right within one session
    // and wrong across two: the couple that finally appears can belong to
    // somebody else, and flushDeferred would then write the previous account's
    // room into their presence row.
    Diag.resetForTest();
    final c = ProviderContainer(
      overrides: [currentCoupleProvider.overrideWithValue(null)],
    );
    addTearDown(c.dispose);
    final obs = PresenceRouteObserver(_ContainerRef(c));

    obs.didPush(page('/app/touch'), null); // held: no couple to tell
    obs.reset(); // the session ends
    obs.flushDeferred(); // a DIFFERENT couple binds

    final replayed = Diag.recent
        .where((e) =>
            e.name == 'presence_screen_publish' &&
            e.fields['src'] == 'couple_ready',)
        .toList();
    expect(replayed, isEmpty,
        reason: 'the room held under the previous identity was replayed into '
            'the next couple: ${replayed.map((e) => e.fields)}',);
  });

  test('a stale live hint does not swallow the first hint of the next couple',
      () {
    // Hints are ordered by the SENDER's clock, which is a different person's
    // clock after a re-pair. One left behind at a later wall time silently
    // drops every hint the next partner sends until their clock passes it.
    PresenceService.resetLiveHint(); // liveHint is static: start from empty
    PresenceService.applyLiveHint(
      online: true,
      at: DateTime.utc(2026, 8, 29, 12),
    );
    PresenceService.resetLiveHint();
    PresenceService.applyLiveHint(
      online: true,
      at: DateTime.utc(2026, 8, 29, 11),
    );
    addTearDown(PresenceService.resetLiveHint);

    expect(PresenceService.liveHint.value?.at, DateTime.utc(2026, 8, 29, 11),
        reason: 'the hint from the new partner was dropped as older than the '
            'one the previous couple left behind',);
  });

  test('a stale mood hint does not swallow the first mood of the next couple',
      () {
    // The liveHint case, for the other thing the socket carries by the
    // sender's clock.
    PresenceService.resetMoodHint();
    PresenceService.applyMoodHint(
      mood: 'angry',
      at: DateTime.utc(2026, 8, 29, 12),
    );
    PresenceService.resetMoodHint();
    PresenceService.applyMoodHint(
      mood: 'calm',
      at: DateTime.utc(2026, 8, 29, 11),
    );
    addTearDown(PresenceService.resetMoodHint);

    expect(PresenceService.moodHint.value?.mood, 'calm',
        reason: "the next partner's first mood was dropped as older than the "
            'one the previous couple left behind',);
  });

  test('a session the SERVER ends unbinds the handset too', () {
    // signOut() unbinds the device before it leaves, but a revoked or expired
    // refresh token never passes through signOut() — it arrives as an event
    // and lands in _endSession alone. So the unbind belongs on that one door,
    // where a future way of ending a session cannot forget it.
    final src = File('lib/core/app/session_provider.dart').readAsStringSync();
    final endSession = src.substring(src.indexOf('Future<void> _endSession()'));
    expect(endSession, contains('FcmService.forgetDevice()'));
  });
}

/// PresenceRouteObserver only ever `read`s providers, which a container does.
class _ContainerRef implements Ref {
  _ContainerRef(this._c);
  final ProviderContainer _c;

  @override
  T read<T>(ProviderListenable<T> provider) => _c.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
