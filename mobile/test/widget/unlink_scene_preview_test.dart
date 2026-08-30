@Tags(['preview'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/tilt_parallax.dart';
import 'package:miles/features/unlink/scene/ritual_scene.dart';
import 'package:miles/features/unlink/scene/scene_assets.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Doorstep, rendered to PNGs so the direction can be LOOKED AT.
///
/// The stage itself, mounted directly — the same painters, the same beats,
/// the same clock the phone runs. Staged pumps land each shot mid-pose: a
/// repeating ticker makes `pumpAndSettle` hang, so time is advanced by
/// explicit amounts and the seeded star field keeps every byte stable.
///
///   flutter test --tags preview --run-skipped --update-goldens \
///     test/widget/unlink_scene_preview_test.dart
void main() {
  setUpAll(() async {
    for (final family in ['Fraunces', 'Inter']) {
      final loader = FontLoader(family);
      for (final f
          in Directory('assets/fonts').listSync().whereType<File>()) {
        if (!f.path.contains(family)) continue;
        loader.addFont(
          Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())),
        );
      }
      await loader.load();
    }
    // The owner's art, decoded before the first shot — the stage swaps the
    // bitmaps in asynchronously on a phone, and a golden of the pre-load
    // frame would be a preview of the wrong world.
    await SceneArt.ensureLoaded();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // A beat fires a cue; there is no audio plugin behind a test — and no
    // accelerometer behind the stage's parallax either.
    MilesSound.enabled = false;
    TiltParallax.debugDefaultSource = const Stream.empty();
  });

  tearDown(UnlinkState.reset);

  UnlinkRow row({
    Duration age = const Duration(hours: 2),
    String state = 'cooling',
    Duration? lastLookIn,
    bool withNote = false,
  }) {
    final s = DateTime.now().toUtc().subtract(age);
    return UnlinkRow(
      coupleId: 'cccccccc-0000-0000-0000-000000000003',
      initiatedBy: 'aaaaaaaa-0000-0000-0000-000000000001',
      state: state,
      startedAt: s,
      coolingEndsAt: s.add(const Duration(hours: 24)),
      lastLookEndsAt: lastLookIn == null
          ? null
          : DateTime.now().toUtc().add(lastLookIn),
      acceptedAt: null,
      relinkOpensAt: s.add(const Duration(minutes: 15)),
      partnerGateOpensAt: s.add(const Duration(minutes: 15)),
      noteCipherBytea: withNote ? r'\xdead' : null,
      noteNonceBytea: withNote ? r'\x01' : null,
      noteAuthor: null,
      noteUpdatedAt:
          withNote ? DateTime.now().toUtc().subtract(age ~/ 2) : null,
    );
  }

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required UnlinkRow r,
    PuppetVariant variant = PuppetVariant.male,
    SceneRole role = SceneRole.outside,
    List<Duration> pumps = const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 1600),
      Duration(milliseconds: 1300),
    ],
  }) async {
    UnlinkState.applyRow(null);
    UnlinkState.current.value = null;
    await tester.binding.setSurfaceSize(const Size(360, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: milesDarkTheme(),
        home: ColoredBox(
          color: MilesColors.night,
          child: Center(
            child: SizedBox(
              width: 344,
              child: RitualScene(
                row: r,
                role: role,
                variant: variant,
                quoteText:
                    'In dreams and in love there are no impossibilities.',
                quoteAuthor: 'János Arany',
              ),
            ),
          ),
        ),
      ),
    );
    for (final d in pumps) {
      await tester.pump(d);
    }
    await expectLater(
      find.byType(RitualScene),
      matchesGoldenFile('preview/scene_$name.png'),
    );
  }

  testWidgets('1 · settled street, bird and quote', (t) async {
    await shoot(t, 'settled_male', r: row());
  });

  testWidgets('2 · mid-slam', (t) async {
    await shoot(
      t,
      'slam',
      r: row(age: const Duration(seconds: 5)),
      pumps: const [Duration(milliseconds: 10), Duration(milliseconds: 320)],
    );
  });

  testWidgets('3 · the way back — handle glowing', (t) async {
    // Two hours in, the gate is long open on the outside view.
    await shoot(t, 'relink_open', r: row());
  });

  testWidgets('4 · last call — bolt shut', (t) async {
    await shoot(
      t,
      'last_call',
      r: row(state: 'last_look', lastLookIn: const Duration(minutes: 4)),
    );
  });

  testWidgets('5 · her side of the street', (t) async {
    await shoot(t, 'settled_female', r: row(), variant: PuppetVariant.female);
  });

  testWidgets('6 · the neutral figure', (t) async {
    await shoot(
      t,
      'settled_neutral',
      r: row(),
      variant: PuppetVariant.neutral,
    );
  });

  testWidgets('7 · near dawn — twenty hours in', (t) async {
    await shoot(t, 'dawn', r: row(age: const Duration(hours: 20)));
  });

  testWidgets('8a · inside the house — her side of the door', (t) async {
    await shoot(
      t,
      'inside_settled',
      r: row(),
      role: SceneRole.inside,
      variant: PuppetVariant.female,
    );
  });

  testWidgets('8b · inside at last call — the bolt shut', (t) async {
    await shoot(
      t,
      'inside_last_call',
      r: row(state: 'last_look', lastLookIn: const Duration(minutes: 4)),
      role: SceneRole.inside,
      variant: PuppetVariant.female,
    );
  });

  testWidgets('8 · the letter, resting on the doorstep', (t) async {
    // A cold start with a note: no arrival replay, the envelope simply lies
    // where it fell, breathing gilt.
    await shoot(t, 'letter_resting', r: row(withNote: true));
  });

  Future<void> shootArrival(
    WidgetTester tester,
    String name,
    SceneRole role,
  ) async {
    // The arrival is an EDGE — two samples. Mount settled without a note,
    // then land the write mid-test the way the realtime rail would, and
    // catch the envelope mid-flight.
    UnlinkState.current.value = null;
    await tester.binding.setSurfaceSize(const Size(360, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final before = row();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: milesDarkTheme(),
        home: ColoredBox(
          color: MilesColors.night,
          child: Center(
            child: SizedBox(
              width: 344,
              child: RitualScene(
                row: before,
                role: role,
                variant: PuppetVariant.male,
                quoteText:
                    'In dreams and in love there are no impossibilities.',
                quoteAuthor: 'János Arany',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 10));
    // The speak beat holds the stage until the LAST word lands (1400ms
    // flight + 9 × 260ms words); a note that arrives sooner queues politely
    // behind it and the shot would catch the queue, not the flight.
    await tester.pump(const Duration(milliseconds: 4000)); // quote finished
    UnlinkState.current.value = row(withNote: true);
    await tester.pump(const Duration(milliseconds: 10)); // beat queued
    await tester.pump(const Duration(milliseconds: 380)); // mid-flight
    await expectLater(
      find.byType(RitualScene),
      matchesGoldenFile('preview/scene_$name.png'),
    );
  }

  testWidgets('9 · the letter arriving — door cracked, envelope out',
      (t) async {
    await shootArrival(t, 'letter_arriving', SceneRole.outside);
  });

  testWidgets('10 · sliding it under, from inside', (t) async {
    await shootArrival(t, 'letter_under', SceneRole.inside);
  });
}
