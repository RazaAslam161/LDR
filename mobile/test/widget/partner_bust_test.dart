import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/widgets/partner_bust.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/presence_character.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// Presence is the one thing in this app that speaks about a real person while
/// they are not there to correct it. Showing them somewhere they are not — or
/// offering to follow them somewhere private — is not a cosmetic bug, so the
/// states this face can be in are pinned here.
///
/// Descended from partner_here_badge_test (531c02a^) through the standing
/// figure. The RULES about where they are did not change; what "shown"
/// means did, deliberately: the face is ALWAYS painted once we know who they
/// are — it wears their last mood — and being away drains its colour rather
/// than removing it. The owner's decision, 2026-09-02.
void main() {
  // The busts are decoded ONCE, here, and never from inside a test body.
  // `PresenceArt.ensureLoaded` is real bundle I/O: called under testWidgets it
  // completes inside the fake-async zone and lands mid-`pump`, which aborts
  // that test AND every one after it with "Guarded function conflict".
  setUpAll(() async {
    for (final v in [PuppetVariant.male, PuppetVariant.female]) {
      await PresenceArt.ensureLoaded(v, 'neutral');
      await PresenceArt.ensureLoaded(v, 'angry');
    }
  });

  setUp(PresenceService.resetMoodHint);

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

  late GoRouter router;

  Future<void> pump(
    WidgetTester tester, {
    required String? myScreen,
    required String? theirScreen,
    bool fresh = true,
    String at = '/app/care',
    String? gender = 'female',
    String? mood,
    bool animationsOff = false,
  }) async {
    router = GoRouter(
      initialLocation: at,
      routes: [
        for (final path in ['/app', '/app/touch', '/app/care'])
          GoRoute(
            path: path,
            // Mounted the way every screen mounts it: in the AppBar's actions.
            builder: (_, __) => MediaQuery(
              data: MediaQueryData(disableAnimations: animationsOff),
              child: Scaffold(
                appBar: AppBar(actions: const [PartnerHereAction()]),
              ),
            ),
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Null couple: every notifier binds on a non-null couple and skips
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
          partnerMoodProvider.overrideWith((ref) => _StubMood(ref, mood)),
          myScreenProvider.overrideWith((ref) => myScreen),
          // joinPartner navigates through the provider, never a context (the
          // figure once lived above the Router and GoRouter.of threw on every
          // tap — build 73). The test's router has to BE that provider.
          routerProvider.overrideWithValue(router),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<String> settleTo(WidgetTester tester) async {
    // The face breathes while they are online, so pumpAndSettle would never
    // return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return router.state.uri.path;
  }

  PresenceCharacter face(WidgetTester tester) =>
      tester.widget<PresenceCharacter>(find.byType(PresenceCharacter));

  GestureDetector gesture(WidgetTester tester) => tester.widget<GestureDetector>(
        find.descendant(
          of: find.byType(PartnerHereAction),
          matching: find.byType(GestureDetector),
        ),
      );

  /// The bust's own painter, read for the cross-fade laws.
  dynamic painter(WidgetTester tester) => tester
      .widget<CustomPaint>(
        find.descendant(
          of: find.byType(PresenceCharacter),
          matching: find.byType(CustomPaint),
        ),
      )
      .painter;

  testWidgets('wears the partner face, for either gender', (tester) async {
    for (final gender in ['male', 'female']) {
      await pump(tester, myScreen: 'Touch', theirScreen: 'Touch', gender: gender);
      expect(find.byType(PresenceCharacter), findsOneWidget,
          reason: '$gender should wear a face',);
      expect(find.text('R'), findsNothing,
          reason: '$gender fell back to the letter',);
    }
  });

  testWidgets('keeps the initial when the profile has no gender',
      (tester) async {
    // Role-setup has a sign-out escape from a failed save, so accounts with a
    // null gender exist by design. Asserted with both busts already decoded,
    // so this proves the neutral branch, not an asset that had not loaded.
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch', gender: null);
    expect(find.text('R'), findsOneWidget);
  });

  testWidgets('together: in colour, tappable, and the tap warms the room',
      (tester) async {
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch');
    expect(face(tester).here, isTrue);
    expect(gesture(tester).onTap, isNotNull);
    await tester.tap(find.byType(PartnerHereAction));
    expect(await settleTo(tester), '/app/care',
        reason: 'together, the tap goes nowhere',);
  });

  testWidgets('somewhere you can follow: in colour, and the tap goes there',
      (tester) async {
    await pump(tester, myScreen: 'Touch', theirScreen: 'Care', at: '/app');
    expect(face(tester).here, isTrue);
    await tester.tap(find.byType(PartnerHereAction));
    expect(await settleTo(tester), '/app/care');
  });

  testWidgets('tapping does nothing when we are already in that room',
      (tester) async {
    await pump(tester, myScreen: null, theirScreen: 'Care');
    await tester.tap(find.byType(PartnerHereAction));
    expect(await settleTo(tester), '/app/care');
    expect(find.byType(PartnerHereAction), findsOneWidget); // not stacked
  });

  group('CHANGED FROM THE BADGE: away is drained, never gone', () {
    // The badge scaled to nothing for a private room, a stale heartbeat or an
    // unknown screen. A face that wears a mood has something to say in all
    // three: the mood. So it stays, loses its colour, and stops offering a
    // trip it cannot make.
    for (final (name, mine, theirs, fresh) in [
      ('somewhere private', 'Chat', 'Vault', true),
      ('gone stale', 'Touch', 'Touch', false),
      ('unknown', 'Chat', null, true),
    ]) {
      testWidgets(name, (tester) async {
        await pump(tester, myScreen: mine, theirScreen: theirs, fresh: fresh);
        expect(find.byType(PresenceCharacter), findsOneWidget,
            reason: 'the face stays',);
        if (!fresh) {
          expect(face(tester).here, isFalse, reason: 'colour drains');
          expect(tester.binding.transientCallbackCount, 0,
              reason: 'nothing ticks for a partner who is not there',);
        }
        expect(gesture(tester).onTap, isNull,
            reason: 'no trip to offer: inert, not broken',);
      });
    }
  });

  testWidgets('still points to them before our own screen is published',
      (tester) async {
    await pump(tester, myScreen: null, theirScreen: 'Touch');
    expect(gesture(tester).onTap, isNotNull);
  });

  testWidgets('the label names them and their mood', (tester) async {
    await pump(tester, myScreen: 'Touch', theirScreen: 'Touch', mood: 'angry');
    expect(find.bySemanticsLabel(RegExp('Rida is angry')), findsOneWidget);
  });

  group('a mood landing is a cross-fade, not a cut', () {
    // Driven at the face itself, through the same didUpdateWidget the host
    // path takes; the host adds only the moodByKey mapping.
    Widget host(String mood, {bool animationsOff = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: animationsOff),
            child: Center(
              child: PresenceCharacter(
                variant: PuppetVariant.female,
                size: 34,
                disc: false,
                mood: mood,
                fallback: const SizedBox.shrink(),
              ),
            ),
          ),
        );

    testWidgets('the old face fades under the new one, then leaves',
        (tester) async {
      await tester.pumpWidget(host('neutral'));
      await tester.pump();
      expect(painter(tester).prev, isNull, reason: 'nothing fading at rest');

      await tester.pumpWidget(host('angry'));
      await tester.pump(); // the decode's then, and the first fading frame
      expect(painter(tester).prev, isNotNull,
          reason: 'the previous expression is still on stage',);
      expect(painter(tester).swap, lessThan(1.0));

      // One frame PAST the duration: a simulation is done when t > duration,
      // strictly, so at exactly 420ms the value is 1.0 and the status is
      // still `forward`. The phone's next frame lands 16ms later.
      await tester.pump(MilesMotion.settle);
      await tester.pump(const Duration(milliseconds: 16));
      expect(painter(tester).prev, isNull,
          reason: 'the fade is over and the old face has gone',);
    });

    testWidgets('reduce-motion swaps the frame and fades nothing',
        (tester) async {
      await tester.pumpWidget(host('neutral', animationsOff: true));
      await tester.pump();
      await tester.pumpWidget(host('angry', animationsOff: true));
      await tester.pump();
      expect(painter(tester).prev, isNull);
      expect(painter(tester).swap, 1.0);
    });
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

class _StubMood extends PartnerMoodNotifier {
  _StubMood(super.ref, String? mood) {
    state = mood;
  }

  void set(String? mood) => state = mood;
}
