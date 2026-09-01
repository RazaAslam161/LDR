@Tags(['preview'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/presence_character.dart' show PresenceArt;
import 'package:miles/core/widgets/presence_figure.dart';
import 'package:miles/features/unlink/scene/scene_state.dart';

/// The standing figure, rendered to a PNG so the direction can be LOOKED at.
///
///   flutter test --tags preview --run-skipped --update-goldens \
///     test/widget/presence_figure_preview_test.dart
void main() {
  setUpAll(() async {
    // Without this, every label renders as a filled box and the sheet is
    // unreadable where it matters least but most distractingly.
    for (final family in ['Inter']) {
      final loader = FontLoader(family);
      for (final f in Directory('assets/fonts').listSync().whereType<File>()) {
        if (!f.path.contains(family)) continue;
        loader.addFont(Future<ByteData>.value(
          ByteData.sublistView(f.readAsBytesSync()),
        ),);
      }
      await loader.load();
    }
    for (final v in [PuppetVariant.male, PuppetVariant.female]) {
      await PresenceArt.ensureFigureLoaded(v);
    }
  });

  testWidgets('the figure, at the size it actually stands', (tester) async {
    await tester.binding.setSurfaceSize(const Size(920, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Every state the corner can be in, side by side and at true scale: the
    // entrance mid-rise, settled and here, and settled but elsewhere.
    const cases = [
      (PuppetVariant.male, 0.45, true, 'arriving'),
      (PuppetVariant.male, 1.0, true, 'here'),
      (PuppetVariant.male, 1.0, false, 'elsewhere'),
      (PuppetVariant.female, 0.45, true, 'arriving'),
      (PuppetVariant.female, 1.0, true, 'here'),
      (PuppetVariant.female, 1.0, false, 'elsewhere'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ColoredBox(
          color: MilesColors.night,
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final (variant, arrive, here, label) in cases)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 160,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: PresenceFigure(
                            variant: variant,
                            height: 116,
                            here: here,
                            turn: 1.2,
                            arrive: arrive,
                            tint: MilesColors.ember,
                          ),
                        ),
                      ),
                      Text(
                        label,
                        style: const TextStyle(
                          color: MilesColors.taupe,
                          fontFamily: 'Inter',
                          fontSize: 11,
                          decoration: TextDecoration.none,
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
      matchesGoldenFile('preview/presence_figure.png'),
    );
    expect(File('test/widget/preview/presence_figure.png').existsSync(), isTrue);
  });
}
