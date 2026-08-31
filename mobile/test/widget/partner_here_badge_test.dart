import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/presence_character.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// Presence is the one thing in this app that speaks about a real person while
/// they are not there to correct it. Showing them somewhere they are not — or
/// offering to follow them somewhere private — is not a cosmetic bug, so the
/// states this widget can be in are pinned here.
void main() {
  // The busts are decoded ONCE, here, and never from inside a test body.
  // `PresenceArt.ensureLoaded` is real bundle I/O: called under testWidgets it
  // completes inside the fake-async zone and lands mid-`pump`, which aborts
  // that test AND every one after it with "Guarded function conflict". The
  // Doorstep's SceneArt learned this the same way (BRAIN §228 addendum).
  setUpAll(() async {
    await PresenceArt.ensureLoaded(PuppetVariant.male);
    await PresenceArt.ensureLoaded(PuppetVariant.female);
  });

  Profile me() => Profile(
        id: 'me',
        displayName: 'Ali',
        timezone: 'UTC',
        presenceStatus: PresenceStatus.awake,
        createdAt: DateTime.utc(2026),
      );

  Profile partner({String? gender}) => Profile(
        id: 'p1',
        displayName: 'Rida',
        timezone: 'UTC',
        gender: gender,
        genderSet: gender != null,
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

  /// The live router, so a tap can be checked against where it landed.
  late GoRouter router;

  Future<void> pump(
    WidgetTester tester, {
    required String? myScreen,
    required String? theirScreen,
    bool fresh = true,
    String at = '/app/care',
    String? gender,
  }) async {
    router = GoRouter(
      initialLocation: at,
      routes: [
        for (final path in ['/app', '/app/touch', '/app/care'])
          GoRoute(
            path: path,
            builder: (_, __) =>
                const Scaffold(body: Center(child: PartnerHereBadge())),
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Null couple: both notifiers bind on a non-null couple and skip
          // Supabase entirely without one, which is exactly what a test wants.
          currentCoupleProvider.overrideWithValue(null),
          partnerProfileProvider.overrideWithValue(partner(gender: gender)),
          currentProfileProvider.overrideWithValue(me()),
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
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Where the router actually is, after everything has been pumped.
  Future<String> settleTo(WidgetTester tester) async {
    // The avatar breathes forever, so pumpAndSettle would never return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return router.state.uri.path;
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

  testWidgets('wears the partner face once their bust has decoded',
      (tester) async {
    // The mark shows the PARTNER, so it reads the partner's gender — not the
    // signed-in user's, which is the profile every other gendered feature in
    // the app happens to read.
    for (final gender in ['male', 'female']) {
      await pump(
        tester,
        myScreen: 'Touch',
        theirScreen: 'Touch',
        gender: gender,
      );
      expect(find.byType(PresenceCharacter), findsOneWidget,
          reason: '$gender should wear a face');
      expect(find.text('R'), findsNothing,
          reason: '$gender fell back to the letter',);
    }
  });

  testWidgets('keeps the initial when the profile has no gender',
      (tester) async {
    // Not a defect state: role-setup has a sign-out escape from a failed save,
    // so accounts with a null gender exist by design. Asserted with BOTH busts
    // already decoded (setUpAll), so this proves the neutral branch rather
    // than proving that an asset had not loaded yet.
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch');
    expect(find.text('R'), findsOneWidget);
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

  testWidgets('tapping goes to the room they are in', (tester) async {
    // A pushed room, not a tab: Touch became a bottom-nav tab, and a tab is
    // joined by selecting it rather than by pushing a route.
    await pump(tester, myScreen: 'Touch', theirScreen: 'Care', at: '/app');
    await tester.tap(find.byType(PartnerHereBadge));
    expect(await settleTo(tester), '/app/care');
  });

  testWidgets('tapping does nothing when we are already in that room',
      (tester) async {
    // Reachable in the window before our own screen has been published, and a
    // push would stack a second copy of the page on top of itself.
    await pump(tester, myScreen: null, theirScreen: 'Care');
    await tester.tap(find.byType(PartnerHereBadge));
    expect(await settleTo(tester), '/app/care');
    expect(find.byType(PartnerHereBadge), findsOneWidget); // not stacked twice
  });

  testWidgets('tapping while together navigates nowhere', (tester) async {
    // Together, the tap warms the room. Going somewhere would be the one thing
    // neither of them asked for.
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch');
    await tester.tap(find.byType(PartnerHereBadge));
    expect(await settleTo(tester), '/app/care');
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
