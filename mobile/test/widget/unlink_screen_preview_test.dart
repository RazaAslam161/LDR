@Tags(['preview'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/tilt_parallax.dart';
import 'package:miles/features/unlink/scene/film_library.dart';
import 'package:miles/features/unlink/scene/scene_assets.dart';
import 'package:miles/features/unlink/scene/scene_sync.dart';
import 'package:miles/features/unlink/unlink_screen.dart';
import 'package:miles/features/unlink/unlink_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the ritual to PNGs so the design can be LOOKED AT.
///
/// Not a mockup of the screen — the screen itself, the same widget the phone
/// builds, with the app's real bundled fonts loaded so the text is text rather
/// than the blank boxes `flutter test` draws by default.
///
/// Tagged `preview` and excluded from the default run by dart_test.yaml: it
/// writes files rather than asserting anything, and a suite that rewrites
/// images on every run is not a gate. Produce them with:
///
///   flutter test --tags preview --update-goldens test/widget/unlink_screen_preview_test.dart
void main() {
  // The Doorstep's slam latch lives in SharedPreferences; without a mock the
  // plugin channel would throw inside the scene's initState. The realtime
  // ear is switched off the same way TiltParallax's sensor is: there is no
  // Supabase behind a widget test, and a faked socket would test the fake.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UnlinkSceneSync.debugDisabled = true;
    // A slam beat fires a cue; the audio plugin behind it does not exist in
    // a test, and its DISPOSAL then throws into the NEXT test's zone. The
    // stage's parallax has no accelerometer behind it either.
    MilesSound.enabled = false;
    TiltParallax.debugDefaultSource = const Stream.empty();
  });

  const meId = 'aaaaaaaa-0000-0000-0000-000000000001';
  const themId = 'bbbbbbbb-0000-0000-0000-000000000002';
  const phone = Size(360, 800);

  setUpAll(() async {
    // Without this every glyph renders as an empty box and the "preview" shows
    // nothing about the typography, which is half of what is being judged.
    for (final family in ['Fraunces', 'Inter']) {
      final loader = FontLoader(family);
      final dir = Directory('assets/fonts');
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.contains(family)) continue;
        loader.addFont(
          Future<ByteData>.value(
            ByteData.sublistView(f.readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
    // The stage swaps the owner's bitmaps in asynchronously; the preview
    // must show the world the phone settles on, not the pre-load frame.
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

  // Cleared only once the tree is gone. Resetting while the screen is still
  // mounted fires its own release path, which reads sessionProvider and needs
  // a Supabase client this harness has no reason to stand up.
  tearDown(UnlinkState.reset);

  // Gender set on both, because it IS set for both real people (the
  // funnel's needsRole gate guarantees it) — without it the previews cast
  // the neutral silhouette and judge the wrong scene.
  Profile p(String id, String name, String gender) => Profile(
        id: id,
        displayName: name,
        timezone: 'UTC',
        presenceStatus: PresenceStatus.free,
        createdAt: DateTime.utc(2026),
        gender: gender,
        genderSet: true,
      );

  Map<String, dynamic> ceremony({
    required String initiator,
    required Duration gateIn,
    String state = 'cooling',
    Duration? lastLookIn,
    String? noteCipher,
  }) {
    final now = DateTime.now().toUtc();
    return {
      'couple_id': 'cccccccc-0000-0000-0000-000000000003',
      'initiated_by': initiator,
      'state': state,
      'started_at': now.toIso8601String(),
      'cooling_ends_at': now.add(const Duration(hours: 24)).toIso8601String(),
      'last_look_ends_at':
          lastLookIn == null ? null : now.add(lastLookIn).toIso8601String(),
      'accepted_at': null,
      'relink_opens_at': now.add(gateIn).toIso8601String(),
      'partner_gate_opens_at': now.add(gateIn).toIso8601String(),
      'note_cipher': noteCipher,
      'note_nonce': noteCipher == null ? null : r'\x01',
      'note_author': noteCipher == null ? null : themId,
      'note_updated_at': null,
    };
  }

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Map<String, dynamic> row,
  ) async {
    UnlinkState.applyRow(row);
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentProfileProvider.overrideWithValue(p(meId, 'Steve', 'male')),
          partnerProfileProvider
              .overrideWithValue(p(themId, 'Ayesha', 'female')),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: milesDarkTheme(),
          home: const MediaQuery(
            data: MediaQueryData(size: phone),
            child: UnlinkScreen(),
          ),
        ),
      ),
    );
    await tester.pump();
    await expectLater(
      find.byType(UnlinkScreen),
      matchesGoldenFile('preview/$name.png'),
    );
  }

  testWidgets('1 · the one who left, waiting', (t) async {
    await shoot(t, 'initiator_waiting',
        ceremony(initiator: meId, gateIn: const Duration(minutes: 15)),);
  });

  testWidgets('2 · the one who left, way back open', (t) async {
    await shoot(t, 'initiator_relink',
        ceremony(initiator: meId, gateIn: const Duration(minutes: -1)),);
  });

  testWidgets('3 · the one being left, waiting', (t) async {
    await shoot(t, 'partner_waiting',
        ceremony(initiator: themId, gateIn: const Duration(minutes: 15)),);
  });

  testWidgets('4 · the one being left, can decide', (t) async {
    await shoot(t, 'partner_open',
        ceremony(initiator: themId, gateIn: const Duration(minutes: -1)),);
  });

  testWidgets('5 · last call', (t) async {
    await shoot(
      t,
      'last_call',
      ceremony(
        initiator: meId,
        gateIn: const Duration(minutes: -1),
        state: 'last_look',
        lastLookIn: const Duration(minutes: 5),
      ),
    );
  });
}
