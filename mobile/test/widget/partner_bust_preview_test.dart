@Tags(['preview'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/mood.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/presence_character.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// Every expression, rendered so it can be LOOKED at before it ships.
///
///   flutter test --tags preview --run-skipped --update-goldens \
///     test/widget/partner_bust_preview_test.dart
///
/// Two rows per character: the face at the 34dp it stands at in the AppBar,
/// and at 4x, so "is the anger readable at thumbnail size" is a decision made
/// on purpose and not discovered on a handset. Until the cast lands every
/// cell wears neutral — still worth a look for the free-standing edge, the
/// shoulder pool and the drained-colour state.
void main() {
  setUpAll(() async {
    // Without the real face, every label renders as a filled box — the
    // doorstep preview's loader, family by family.
    final loader = FontLoader('Inter');
    for (final f in Directory('assets/fonts').listSync().whereType<File>()) {
      if (!f.path.contains('Inter')) continue;
      loader.addFont(
        Future<ByteData>.value(ByteData.sublistView(f.readAsBytesSync())),
      );
    }
    await loader.load();
    // Every frame, decoded HERE and held: the grid shows all forty at once,
    // and a decode landing mid-pump is the Guarded-function-conflict crash.
    PresenceArt.keep = 64;
    for (final v in [PuppetVariant.male, PuppetVariant.female]) {
      await PresenceArt.ensureLoaded(v, 'neutral');
      for (final m in kMoods) {
        await PresenceArt.ensureLoaded(v, m.artName);
      }
    }
  });
  tearDownAll(() => PresenceArt.keep = 4);

  final moods = <String?>[null, ...kMoods.map((m) => m.artName)];

  Widget cell(PuppetVariant v, String? mood, double size, {bool here = true}) =>
      Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PresenceCharacter(
              variant: v,
              size: size,
              disc: false,
              mood: mood,
              turn: 1.2,
              here: here,
              tint: moodByKey(mood)?.color ?? MilesColors.ember,
              fallback: const SizedBox.shrink(),
            ),
            if (size > 60)
              Text(
                mood ?? 'neutral',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  color: MilesColors.taupe,
                  fontSize: 9,
                ),
              ),
          ],
        ),
      );

  testWidgets('every mood, both characters, small and large', (tester) async {
    await tester.binding.setSurfaceSize(const Size(2000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: MilesColors.night,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final v in [PuppetVariant.male, PuppetVariant.female]) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [for (final m in moods) cell(v, m, 34)],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [for (final m in moods) cell(v, m, 80)],
                ),
              ],
              // The two liveness states, side by side.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  cell(PuppetVariant.male, null, 80),
                  cell(PuppetVariant.male, null, 80, here: false),
                  cell(PuppetVariant.female, null, 80),
                  cell(PuppetVariant.female, null, 80, here: false),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/presence_moods.png'),
    );
    expect(File('test/widget/preview/presence_moods.png').existsSync(), isTrue);
  });

  testWidgets('a cross-fade, caught halfway', (tester) async {
    // The one thing a still cannot show and the handset would show first: two
    // expressions sharing one head mid-swap.
    await tester.binding.setSurfaceSize(const Size(600, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget host(String mood) => MaterialApp(
          debugShowCheckedModeBanner: false,
          home: ColoredBox(
            color: MilesColors.night,
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  cell(PuppetVariant.male, mood, 176),
                  cell(PuppetVariant.female, mood, 176),
                ],
              ),
            ),
          ),
        );
    await tester.pumpWidget(host('neutral'));
    await tester.pump();
    await tester.pumpWidget(host('angry'));
    await tester.pump();
    await tester.pump(MilesMotion.settle ~/ 2);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/presence_fade.png'),
    );
  });
}
