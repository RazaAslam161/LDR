import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/ember_background.dart';

/// The rewrite's contracts. On-device frame timing is a BLOCKED-owner item;
/// what CAN be proven on the host is proven here: the ticker's on/off logic
/// and that the atlas path actually puts light on the canvas.
void main() {
  Widget app({bool animationsOff = false, Widget? inner}) => MaterialApp(
        home: EmberBackground(
          child: inner ?? const SizedBox.expand(),
        ),
        builder: !animationsOff
            ? null
            : (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: child!,
                ),
      );

  testWidgets('the field ticks when visible', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('EmberBackgroundHidden stops the ticker, disposal resumes it',
      (tester) async {
    await tester.pumpWidget(app(inner: const SizedBox.expand()));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0),
        reason: 'baseline: the field runs');

    await tester.pumpWidget(app(inner: const EmberBackgroundHidden()));
    await tester.pump();
    expect(EmberBackground.covered.value, 1);
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'a covered field must not keep a vsync loop warm');

    await tester.pumpWidget(app(inner: const SizedBox.expand()));
    await tester.pump();
    expect(EmberBackground.covered.value, 0);
    expect(tester.binding.transientCallbackCount, greaterThan(0),
        reason: 'uncovering resumes the breath');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('animations off = one fixed frame, zero tickers',
      (tester) async {
    await tester.pumpWidget(app(animationsOff: true));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(find.byType(CustomPaint), findsWidgets,
        reason: 'off() paints the finished field, not a blank');
  });

  testWidgets('a wish crosses only where the marker is mounted',
      (tester) async {
    // Both renders sit at the SAME point in the ambient loop, so the ember
    // field, the glow and every star are identical between them — the only
    // possible difference is the wish itself.
    Future<int> litAtWishFrame({required bool wishing}) async {
      await tester.pumpWidget(RepaintBoundary(
        child: app(inner: wishing ? const EmberBackgroundWishes() : null),
      ));
      await tester.pump();
      // 0.63 of the 36s loop — inside the wish's flight window.
      await tester.pump(const Duration(milliseconds: 22680));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,);
      late ui.Image img;
      ByteData? bytes;
      await tester.runAsync(() async {
        img = await boundary.toImage();
        bytes = await img.toByteData();
      });
      var lit = 0;
      for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
        if (bytes!.getUint8(i) > 0x60) lit++;
      }
      img.dispose();
      return lit;
    }

    final withWish = await litAtWishFrame(wishing: true);
    final without = await litAtWishFrame(wishing: false);
    expect(EmberBackground.wishing.value, 0,
        reason: 'the marker must release its claim on dispose');
    expect(withWish, greaterThan(without),
        reason: 'the wish adds bright pixels at its frame; without the '
            'marker the same frame must be unchanged');
  });

  testWidgets('a marker inside a scrolling list loses its claim — which is '
      'why Home mounts it in the body', (tester) async {
    // Documentation by demonstration. This is the hazard the widget's doc
    // comment warns about: it is Flutter behaving correctly (a list frees
    // what has scrolled far away), which is exactly why the marker must not
    // live in one.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            const EmberBackgroundWishes(),
            for (var i = 0; i < 30; i++)
              SizedBox(height: 400, child: Text('row $i')),
          ],
        ),
      ),
    ));
    await tester.pump();
    expect(EmberBackground.wishing.value, 1);

    await tester.fling(find.byType(ListView), const Offset(0, -6000), 4000);
    await tester.pumpAndSettle();
    expect(EmberBackground.wishing.value, 0,
        reason: 'scrolled past the cache extent, the list disposed it — a '
            'wish must not depend on where the page is scrolled');

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(EmberBackground.wishing.value, 0);
  });

  testWidgets('the atlas path actually draws light', (tester) async {
    await tester.pumpWidget(
      RepaintBoundary(child: app(animationsOff: true)),
    );
    await tester.pump();
    final boundary = tester
        .renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
    late ui.Image img;
    ByteData? bytes;
    await tester.runAsync(() async {
      img = await boundary.toImage();
      bytes = await img.toByteData();
    });
    var lit = 0;
    for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
      final r = bytes!.getUint8(i);
      // Anything meaningfully brighter than the night base (0x12) proves the
      // glow texture and sprites rendered — a broken toImageSync path would
      // leave a flat dark rect.
      if (r > 0x30) lit++;
    }
    expect(lit, greaterThan(100),
        reason: 'the cached glow / sprite atlases drew nothing — the field '
            'is dark');
    img.dispose();
  });
}
