import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/models.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';

/// Presence is the one thing in this app that speaks about a real person while
/// they are not there to correct it. Showing them somewhere they are not — or
/// offering to follow them somewhere private — is not a cosmetic bug, so the
/// states this widget can be in are pinned here.
void main() {
  Profile partner() => Profile(
        id: 'p1',
        displayName: 'Rida',
        timezone: 'UTC',
        presenceStatus: PresenceStatus.awake,
        createdAt: DateTime.utc(2026),
      );

  Presence presence({required String? screen, bool fresh = true}) => Presence(
        userId: 'p1',
        currentScreen: screen,
        // isTrulyOnline is a 45s window on this timestamp.
        appLastActiveAt: DateTime.now().toUtc().subtract(
              fresh ? const Duration(seconds: 5) : const Duration(minutes: 10),
            ),
      );

  Future<void> pump(
    WidgetTester tester, {
    required String? myScreen,
    required String? theirScreen,
    bool fresh = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Null couple: both notifiers bind on a non-null couple and skip
          // Supabase entirely without one, which is exactly what a test wants.
          currentCoupleProvider.overrideWithValue(null),
          partnerProfileProvider.overrideWithValue(partner()),
          partnerPresenceProvider.overrideWith(
            (ref) => _StubPresence(
              ref,
              presence(screen: theirScreen, fresh: fresh),
            ),
          ),
          partnerScreenProvider
              .overrideWith((ref) => _StubScreen(ref, theirScreen)),
          myScreenProvider.overrideWith((ref) => myScreen),
        ],
        child: const MaterialApp(
          home: Scaffold(body: Center(child: PartnerHereBadge())),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The badge collapses to nothing rather than unmounting, so "not shown"
  /// means zero scale — which is also what keeps it from shoving a layout
  /// around as it comes and goes.
  double scaleOf(WidgetTester tester) =>
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

  testWidgets('shows when they are on the same screen', (tester) async {
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch');
    expect(scaleOf(tester), 1.0);
    expect(find.text('R'), findsOneWidget); // their initial, no name banner
  });

  testWidgets('still shows when they are somewhere else you can follow',
      (tester) async {
    await pump(tester, myScreen: 'Chat', theirScreen: 'Touch');
    expect(scaleOf(tester), 1.0);
  });

  testWidgets('hides when they are somewhere private', (tester) async {
    // Following them into the vault would betray the one place in the app that
    // is meant to be theirs alone — so there is nothing to tap and nothing to
    // see.
    await pump(tester, myScreen: 'Chat', theirScreen: 'Vault');
    expect(scaleOf(tester), 0.0);
  });

  testWidgets('hides when their presence has gone stale', (tester) async {
    // The 45s window has passed: we no longer know where they are, and a
    // confident wrong answer is worse than none.
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch', fresh: false);
    expect(scaleOf(tester), 0.0);
  });

  testWidgets('still points to them before our own screen is published',
      (tester) async {
    // Where THEY are does not depend on knowing where WE are, and there is a
    // window at launch before the first route has reported.
    await pump(tester, myScreen: null, theirScreen: 'Touch');
    expect(scaleOf(tester), 1.0);
  });

  testWidgets('hides when we know nothing about where they are',
      (tester) async {
    await pump(tester, myScreen: 'Chat', theirScreen: null);
    expect(scaleOf(tester), 0.0);
  });

  testWidgets('is tappable when together, and when they are joinable',
      (tester) async {
    for (final (mine, theirs) in [('Touch', 'Touch'), ('Chat', 'Touch')]) {
      await pump(tester, myScreen: mine, theirScreen: theirs);
      final gesture = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(PartnerHereBadge),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(gesture.onTap, isNotNull, reason: '$mine -> $theirs should tap');
    }
  });
}

class _StubPresence extends PartnerPresenceNotifier {
  _StubPresence(super.ref, Presence? value) {
    state = value;
  }
}

class _StubScreen extends PartnerScreenNotifier {
  _StubScreen(super.ref, String? screen) {
    state = screen;
  }
}
