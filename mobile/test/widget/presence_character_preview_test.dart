@Tags(['preview'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/core/widgets/presence_character.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// The presence cast, rendered to a PNG so the direction can be LOOKED AT.
///
/// The badges below are the REAL [PartnerHereBadge] — same providers, same
/// derivation, same disc — because the one thing a hand-built replica cannot
/// preview is the widget that actually ships. Only Home's 64dp circle is
/// replicated (a ClipOval over a 64dp surface-2 box, which is all `_Avatar`'s
/// container is), because mounting Home means mounting Supabase.
///
///   flutter test --tags preview --run-skipped --update-goldens \
///     test/widget/presence_character_preview_test.dart
void main() {
  setUpAll(() async {
    for (final family in ['Fraunces', 'Inter']) {
      final loader = FontLoader(family);
      for (final f in Directory('assets/fonts').listSync().whereType<File>()) {
        if (!f.path.contains(family)) continue;
        loader.addFont(Future<ByteData>.value(
          ByteData.sublistView(f.readAsBytesSync()),
        ),);
      }
      await loader.load();
    }
    // Both busts decoded before the first shot — a golden of the pre-load
    // frame would be a preview of the letter, which is not what is under test.
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

  Profile partner(String? gender) => Profile(
        id: 'p1',
        displayName: 'Rida',
        timezone: 'UTC',
        gender: gender,
        genderSet: gender != null,
        presenceStatus: PresenceStatus.awake,
        createdAt: DateTime.utc(2026),
      );

  Presence presence(String? screen) => Presence(
        userId: 'p1',
        currentScreen: screen,
        appLastActiveAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
      );

  /// One real badge, in its own provider scope so a sheet can hold several.
  Widget badge({
    required String? gender,
    required String myScreen,
    required String theirScreen,
  }) =>
      ProviderScope(
        overrides: [
          currentCoupleProvider.overrideWithValue(null),
          partnerProfileProvider.overrideWithValue(partner(gender)),
          currentProfileProvider.overrideWithValue(me()),
          partnerPresenceProvider.overrideWith(
            (ref) => _StubPresence(ref, presence(theirScreen)),
          ),
          partnerScreenProvider
              .overrideWith((ref) => _StubScreen(ref, theirScreen)),
          myScreenProvider.overrideWith((ref) => myScreen),
        ],
        child: const PartnerHereBadge(),
      );

  /// Home's circle: the container `_Avatar` builds, with the same figure in it.
  Widget homeCircle({required PuppetVariant variant, required bool online}) =>
      ClipOval(
        child: Container(
          width: 64,
          height: 64,
          color: MilesColors.surface2,
          child: PresenceCharacter(
            variant: variant,
            diameter: 64,
            here: online,
            fallback: const Center(
              child: Text('R',
                  style: TextStyle(
                      color: MilesColors.cream50, fontSize: 24,),),
            ),
          ),
        ),
      );

  Widget label(String s) => Padding(
        padding: const EdgeInsets.only(top: 6),
        // MilesType, not a bare TextStyle: the default family is not one of
        // the two this harness registers, so a raw style renders tofu and the
        // captions become unreadable blocks.
        child: Text(s,
            textAlign: TextAlign.center,
            style: MilesType.inter(
              fontSize: 9,
              color: MilesColors.taupe,
              // No Material ancestor over these captions, and Flutter's debug
              // style underlines anything without one.
              decoration: TextDecoration.none,
            ),),
      );

  /// Fixed-width so a long caption can never push the sheet wider than the
  /// surface — an overflow stripe in a preview hides the thing being previewed.
  Widget cell(String name, Widget child, {double h = 44}) => SizedBox(
        width: 116,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [SizedBox(height: h, child: Center(child: child)), label(name)],
        ),
      );

  /// Motion cannot be judged from one frame. [PresenceCharacter] takes its
  /// clock as a parameter, so the strip below is the SAME widget stepped by
  /// hand through a stretch of its loop — a real filmstrip, not a mock-up.
  testWidgets('the figure moves — a filmstrip of one loop', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Row 1 walks the idle gaze, starting at turn 0 — which MUST show open
    // eyes, because that is the frame every badge in the app mounts on.
    // Row 2 steps THROUGH a blink: the eyes are shut while
    // `(turn / 2pi + 1.7) % 4.3 < 0.055` — the sixth window is turn
    // 151.425 … 151.770, so 151.2 and 151.85 must be open and the three
    // between them shut. If that stops being true, this golden is how you
    // find out.
    const frames = [
      0.0, 3.6, 7.2, 10.8, 14.4, 18.0,
      151.20, 151.50, 151.60, 151.70, 151.85, 152.10,
    ];

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: milesDarkTheme(),
        home: ColoredBox(
          color: MilesColors.night,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final variant in [
                  PuppetVariant.male,
                  PuppetVariant.female,
                ])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final t in frames)
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: ClipOval(
                            child: ColoredBox(
                              color: MilesColors.surface2,
                              child: PresenceCharacter(
                                variant: variant,
                                diameter: 72,
                                turn: t,
                                fallback: const SizedBox(
                                  width: 72,
                                  height: 72,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/presence_motion.png'),
    );
  });

  testWidgets('the presence cast, every state on one sheet', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 340));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = GoRouter(
      initialLocation: '/app/care',
      routes: [
        GoRoute(
          path: '/app/care',
          builder: (_, __) => ColoredBox(
            color: MilesColors.night,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The badge, as it ships, on all four states it can wear.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      cell(
                        'male · here',
                        badge(
                          gender: 'male',
                          myScreen: 'Care',
                          theirScreen: 'Care',
                        ),
                      ),
                      cell(
                        'female · here',
                        badge(
                          gender: 'female',
                          myScreen: 'Care',
                          theirScreen: 'Care',
                        ),
                      ),
                      cell(
                        'male · elsewhere',
                        badge(
                          gender: 'male',
                          myScreen: 'Care',
                          theirScreen: 'Touch',
                        ),
                      ),
                      cell(
                        'female · elsewhere',
                        badge(
                          gender: 'female',
                          myScreen: 'Care',
                          theirScreen: 'Touch',
                        ),
                      ),
                      cell(
                        'no gender · letter',
                        badge(
                          gender: null,
                          myScreen: 'Care',
                          theirScreen: 'Care',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  // Animations off: the figure stands, nothing ticks.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      cell(
                        'male · motion off',
                        MediaQuery(
                          data: const MediaQueryData(disableAnimations: true),
                          child: badge(
                            gender: 'male',
                            myScreen: 'Care',
                            theirScreen: 'Care',
                          ),
                        ),
                      ),
                      cell(
                        'female · motion off',
                        MediaQuery(
                          data: const MediaQueryData(disableAnimations: true),
                          child: badge(
                            gender: 'female',
                            myScreen: 'Care',
                            theirScreen: 'Care',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  // Home's circle, 64dp, both genders, present and away.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (n, v, on) in [
                        ('home male · on', PuppetVariant.male, true),
                        ('home female · on', PuppetVariant.female, true),
                        ('home male · off', PuppetVariant.male, false),
                        ('home female · off', PuppetVariant.female, false),
                      ])
                        cell(n, homeCircle(variant: v, online: on), h: 64),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: milesDarkTheme(),
        routerConfig: router,
      ),
    );
    // Past the arrival dolly and into the breath, at a point where the swell
    // is visible rather than at either end of it.
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 1200));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/presence_sheet.png'),
    );
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
