import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/presence_character.dart';
import 'package:miles/core/widgets/presence_figure.dart';
import 'package:miles/core/widgets/presence_figure_overlay.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// Presence is the one thing in this app that speaks about a real person while
/// they are not there to correct it. Showing them somewhere they are not — or
/// offering to follow them somewhere private — is not a cosmetic bug, so the
/// states this overlay can be in are pinned here.
///
/// Ported from partner_here_badge_test.dart when the mark stopped being a
/// circle in the AppBar and became a whole person standing at the root. The
/// RULES did not change and neither did these tests; only what "shown" looks
/// like. Two things did change, deliberately, and are marked below: the figure
/// unmounts instead of scaling to zero, and a genderless profile now shows
/// nothing rather than an initial.
void main() {
  // The figures are decoded ONCE, here, never from inside a test body.
  // `ensureFigureLoaded` is real bundle I/O: called under testWidgets it
  // completes inside the fake-async zone and lands mid-`pump`, which aborts
  // that test AND every one after it with "Guarded function conflict". The
  // Doorstep's SceneArt learned this the same way (BRAIN §228 addendum).
  setUpAll(() async {
    await PresenceArt.ensureFigureLoaded(PuppetVariant.male);
    await PresenceArt.ensureFigureLoaded(PuppetVariant.female);
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
    String? gender = 'female',
    bool animationsOff = false,
  }) async {
    router = GoRouter(
      initialLocation: at,
      routes: [
        for (final path in ['/app', '/app/touch', '/app/care'])
          GoRoute(
            path: path,
            // Mounted the way main.dart mounts it: filling the screen, above
            // the page, positioning itself.
            builder: (_, __) => MediaQuery(
              data: MediaQueryData(disableAnimations: animationsOff),
              child: const Scaffold(
                body: Stack(
                  children: [Positioned.fill(child: PresenceFigureOverlay())],
                ),
              ),
            ),
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
    // The figure breathes only while it is on stage now, but the knock is
    // still running at 300ms, so pumpAndSettle would still not return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return router.state.uri.path;
  }

  /// Long enough for the whole knock: walk in, hold, walk out.
  Future<void> pumpPastKnock(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 5));

  /// CHANGED FROM THE BADGE: the figure is not painted at all when nobody is
  /// there, where the badge scaled to zero and kept its 44dp. It can afford to
  /// unmount because it sits in an overlay and reserves nobody's layout.
  bool shown(WidgetTester tester) =>
      find.byType(PresenceFigure).evaluate().isNotEmpty;

  testWidgets('stands there when they are on the same screen', (tester) async {
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch');
    expect(shown(tester), isTrue);
  });

  testWidgets('wears the partner face, for either gender', (tester) async {
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
      expect(shown(tester), isTrue, reason: '$gender should stand there');
    }
  });

  testWidgets('shows nobody when the profile has no gender', (tester) async {
    // Not a defect state: role-setup has a sign-out escape from a failed save,
    // so accounts with a null gender exist by design. CHANGED FROM THE BADGE,
    // which drew their initial instead — a letter inside a circle reads as a
    // mark, but a letter standing on the carpet reads as a bug. Asserted with
    // both figures already decoded (setUpAll), so this proves the neutral
    // branch rather than proving an asset had not loaded yet.
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch', gender: null);
    expect(shown(tester), isFalse);
  });

  testWidgets('still stands there when they are somewhere you can follow',
      (tester) async {
    await pump(tester, myScreen: 'Chat', theirScreen: 'Touch');
    expect(shown(tester), isTrue);
  });

  testWidgets('leaves when they are somewhere private', (tester) async {
    // Following them into the vault would betray the one place in the app that
    // is meant to be theirs alone — so there is nothing to tap and nothing to
    // see.
    await pump(tester, myScreen: 'Chat', theirScreen: 'Vault');
    expect(shown(tester), isFalse);
  });

  testWidgets('leaves when their presence has gone stale', (tester) async {
    // The 45s window has passed: we no longer know where they are, and a
    // confident wrong answer is worse than none.
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch', fresh: false);
    expect(shown(tester), isFalse);
  });

  testWidgets('still points to them before our own screen is published',
      (tester) async {
    // Where THEY are does not depend on knowing where WE are, and there is a
    // window at launch before the first route has reported.
    await pump(tester, myScreen: null, theirScreen: 'Touch');
    expect(shown(tester), isTrue);
  });

  testWidgets('leaves when we know nothing about where they are',
      (tester) async {
    await pump(tester, myScreen: 'Chat', theirScreen: null);
    expect(shown(tester), isFalse);
  });

  testWidgets('is tappable when together, and when they are joinable',
      (tester) async {
    for (final (mine, theirs) in [('Touch', 'Touch'), ('Chat', 'Touch')]) {
      await pump(tester, myScreen: mine, theirScreen: theirs);
      final gesture = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(PresenceFigureOverlay),
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
    await tester.tap(find.byType(PresenceFigure));
    expect(await settleTo(tester), '/app/care');
  });

  testWidgets('tapping does nothing when we are already in that room',
      (tester) async {
    // Reachable in the window before our own screen has been published, and a
    // push would stack a second copy of the page on top of itself.
    await pump(tester, myScreen: null, theirScreen: 'Care');
    await tester.tap(find.byType(PresenceFigure));
    expect(await settleTo(tester), '/app/care');
    expect(find.byType(PresenceFigure), findsOneWidget); // not stacked twice
  });

  testWidgets('tapping while together navigates nowhere', (tester) async {
    // Together, the tap warms the room. Going somewhere would be the one thing
    // neither of them asked for.
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch');
    await tester.tap(find.byType(PresenceFigure));
    expect(await settleTo(tester), '/app/care');
  });

  group('presence is an event, not a resident', () {
    // THE WHOLE POINT OF THE REWRITE. The figure used to breathe in the corner
    // for as long as the partner was online — with ten joinable routes, very
    // nearly always — and was reported, twice, as annoying and irritating.
    // Now it arrives, is seen, and leaves; a still dot keeps the fact.
    testWidgets('they walk out again, and a still dot holds the place',
        (tester) async {
      await pump(tester, myScreen: 'Care', theirScreen: 'Care');
      expect(shown(tester), isTrue, reason: 'the arrival must be seen');

      await pumpPastKnock(tester);
      expect(shown(tester), isFalse,
          reason: 'nobody stands in the corner of a screen forever',);
      expect(find.bySemanticsLabel(RegExp('Rida')), findsOneWidget,
          reason: 'the fact survives the performance — the dot is still '
              'there, still tappable, and still says who it is',);
    });

    testWidgets('reduce-motion is told, never performed at', (tester) async {
      await pump(
        tester,
        myScreen: 'Care',
        theirScreen: 'Care',
        animationsOff: true,
      );
      expect(shown(tester), isFalse,
          reason: 'a user who asked their phone to stop animating does not '
              'get a figure walking across it',);
      expect(find.bySemanticsLabel(RegExp('Rida')), findsOneWidget,
          reason: 'they still need to know she is here',);
    });
  });

}

class _StubPresence extends PartnerPresenceNotifier {
  _StubPresence(super.ref, Presence? value) {
    state = value;
  }
}

class _StubScreen extends PartnerScreenNotifier {
  _StubScreen(super.ref, String? value) {
    state = value;
  }
}
