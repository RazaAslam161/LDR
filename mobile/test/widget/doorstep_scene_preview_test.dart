@Tags(['preview'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/unlink/scene/conversation.dart';
import 'package:miles/features/unlink/scene/doorstep_scene.dart';
import 'package:miles/features/unlink/scene/film_library.dart';
import 'package:miles/features/unlink/scene/scene_assets.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/unlink_state.dart';

/// The Doorstep Act II, rendered to a PNG so the staging and the talk can be
/// LOOKED at across the window: the porch and the room, early, mid, at the
/// gate, and deep in the companionship hours.
///
///   flutter test --tags preview --run-skipped --update-goldens \
///     test/widget/doorstep_scene_preview_test.dart
void main() {
  setUpAll(() async {
    for (final family in ['Fraunces', 'Inter']) {
      final loader = FontLoader(family);
      for (final f in Directory('assets/fonts').listSync().whereType<File>()) {
        if (!f.path.contains(family)) continue;
        loader.addFont(
          Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())),
        );
      }
      await loader.load();
    }
    await SceneArt.ensureLoaded();
    for (final p in [
      FilmLibrary.stageOutM,
      FilmLibrary.stageOutF,
      FilmLibrary.stageInM,
      FilmLibrary.stageInF,
    ]) {
      await FilmLibrary.ensureStill(p);
    }
  });

  UnlinkRow row() {
    final start = DateTime.utc(2026, 9, 1, 12);
    return UnlinkRow(
      coupleId: 'c1',
      initiatedBy: 'me',
      state: 'cooling',
      startedAt: start,
      coolingEndsAt: start.add(const Duration(hours: 24)),
      relinkOpensAt: start.add(const Duration(minutes: 15)),
      partnerGateOpensAt: start.add(const Duration(minutes: 15)),
      lastLookEndsAt: null,
      acceptedAt: null,
      noteCipherBytea: null,
      noteNonceBytea: null,
      noteAuthor: null,
      noteUpdatedAt: null,
    );
  }

  testWidgets('porch and room, across the window', (tester) async {
    // A REAL phone's aspect (360x800 -> 0.45), not a convenient rectangle.
    // A preview shaped unlike the device proves nothing about the device,
    // and this scene shipped wrong once already behind exactly that gap.
    const tile = Size(260, 578);
    await tester.binding.setSurfaceSize(
      Size(tile.width * 4 + 50, tile.height * 2 + 30),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // The stage widget owns a live clock, so the preview drives the painter
    // and the conversation DIRECTLY at chosen moments — same law as the
    // Distance preview: goldens cannot move ServerClock.
    const moments = [
      Duration(seconds: 100),
      Duration(seconds: 340),
      Duration(seconds: 555),
      Duration(minutes: 40),
    ];
    const window = Duration(minutes: 15);

    Widget stage(SceneRole role, PuppetVariant variant, Duration at) {
      final talk = at <= window
          ? visibleExchanges(
              role == SceneRole.outside ? birdScript : catScript,
              elapsed: at,
              window: window,
              tail: 3,
              within: spokenLinger,
            )
          : const <Exchange>[];
      final leaning = at <= window
          ? pendingSpeaker(
              role == SceneRole.outside ? birdScript : catScript,
              elapsed: at,
              window: window,
            )
          : null;
      final late = at > window
          ? companionshipLine(
              role == SceneRole.outside
                  ? birdCompanionship
                  : catCompanionship,
              sinceGate: at - window,
              hold: const Duration(minutes: 25),
            )
          : null;
      return SizedBox.fromSize(
        size: tile,
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: stagePainterForTest(
                  role: role,
                  variant: variant,
                  dawn: at.inSeconds / const Duration(hours: 24).inSeconds,
                  still: FilmLibrary.still(
                    FilmLibrary.stage(role: role, me: variant) ?? '',
                  ),
                ),
              ),
              // variant is what makes this preview honest: with it, the
              // talk hangs off the SHIPPED stage's measured heads through
              // the shipped cover fit, not off invented fractions.
              conversationStackForTest(
                lines: talk,
                lateLine: late,
                outside: role == SceneRole.outside,
                pending: leaning,
                canvas: tile,
                variant: variant,
                phoneLine: at == const Duration(minutes: 5)
                    ? 'i shouldn\'t have said that'
                    : null,
                phoneGlow: at == const Duration(minutes: 5),
              ),
            ],
          ),
        ),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: const Color(0xFF000000),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final at in moments)
                      Padding(
                        padding: const EdgeInsets.all(3),
                        child: stage(
                          SceneRole.outside,
                          PuppetVariant.male,
                          at,
                        ),
                      ),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final at in moments)
                      Padding(
                        padding: const EdgeInsets.all(3),
                        child: stage(
                          SceneRole.inside,
                          PuppetVariant.female,
                          at,
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
      matchesGoldenFile('preview/doorstep_scene.png'),
    );
    expect(
      File('test/widget/preview/doorstep_scene.png').existsSync(),
      isTrue,
    );
    // row() is the harness other cases will grow into; touch it so the
    // analyzer keeps it honest until the gate-rising preview lands.
    expect(row().relinkOpensAt.difference(row().startedAt), window);
  });
}
