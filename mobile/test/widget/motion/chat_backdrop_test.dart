import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/theme/chat_backdrop.dart';
import 'package:miles/features/chat/theme/chat_theme.dart';

/// The backdrop's whole justification is that it DITHERS a banding gradient
/// rather than tinting it. Both halves of that are measurable here, so neither
/// is taken on trust: the grain has to be present, and the average colour has
/// to be the gradient's.
void main() {
  const size = Size(200, 400);

  /// The painted backdrop, and — for comparison — the same gradient with no
  /// grain over it, drawn by the same code path minus the second rect.
  Future<ByteData> shoot(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: RepaintBoundary(
            child: SizedBox(width: size.width, height: size.height, child: child),
          ),
        ),
      ),
    );
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    late ui.Image img;
    ByteData? bytes;
    await tester.runAsync(() async {
      img = await boundary.toImage();
      bytes = await img.toByteData();
    });
    img.dispose();
    return bytes!;
  }

  Widget plainGradient(ChatTheme t) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: t.bg.length == 1 ? [t.bg.first, t.bg.first] : t.bg,
          ),
        ),
      );

  double meanLuma(ByteData b) {
    var sum = 0;
    var n = 0;
    for (var i = 0; i < b.lengthInBytes; i += 4) {
      sum += b.getUint8(i) + b.getUint8(i + 1) + b.getUint8(i + 2);
      n += 3;
    }
    return sum / n;
  }

  testWidgets('the grain is actually there — neighbouring pixels differ',
      (tester) async {
    final b = await shoot(tester, const ChatBackdrop(theme: velvet));
    // A pure gradient over 200px changes by well under one step between
    // horizontal neighbours, so on the ungrained version almost every
    // adjacent pair is byte-identical. Grain breaks that.
    var differing = 0;
    var pairs = 0;
    for (var y = 0; y < 400; y++) {
      for (var x = 0; x < 199; x++) {
        final i = (y * 200 + x) * 4;
        if (b.getUint8(i) != b.getUint8(i + 4)) differing++;
        pairs++;
      }
    }
    expect(differing / pairs, greaterThan(0.2),
        reason: 'the backdrop is flat — the grain tile never painted, which '
            'is what a broken toImageSync path looks like');
  });

  testWidgets('it dithers rather than washes — the average colour is the '
      "gradient's", (tester) async {
    final grained = meanLuma(await shoot(tester, const ChatBackdrop(theme: velvet)));
    final plain = meanLuma(await shoot(tester, plainGradient(velvet)));
    // Symmetric grain over BlendMode.overlay must not move the mean. A
    // one-directional grain — the obvious implementation — lifts every black
    // in the theme, and this is the number that catches it.
    expect((grained - plain).abs(), lessThan(1.0),
        reason: 'the grain shifted the average from $plain to $grained; it is '
            'tinting the theme, not dithering it');
  });

  testWidgets('the light theme is dithered too, and not darkened',
      (tester) async {
    // Overlay is self-scaling, so the one light theme is the case where a
    // naive additive grain would clip instead of dither.
    final grained = meanLuma(await shoot(tester, const ChatBackdrop(theme: dawn)));
    final plain = meanLuma(await shoot(tester, plainGradient(dawn)));
    expect((grained - plain).abs(), lessThan(1.0),
        reason: 'light theme mean moved from $plain to $grained');
  });

  testWidgets('nothing animates — chat is the restraint zone', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: ChatBackdrop(theme: velvet),
    ));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0,
        reason: 'the backdrop registered a ticker; it must be static');
  });

  testWidgets('scrolling does not repaint it', (tester) async {
    // The painter is the only thing standing between this and a full-screen
    // repaint per scroll frame, so its shouldRepaint is worth a test of its
    // own rather than trusting the field comparison by eye.
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: ChatBackdrop(theme: velvet),
    ));
    final painter = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!;
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: ChatBackdrop(theme: velvet),
    ));
    final again = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!;
    expect(again.shouldRepaint(painter), isFalse,
        reason: 'an unchanged theme must not repaint the backdrop');
  });

  testWidgets('a theme change DOES repaint it', (tester) async {
    // The other half — a shouldRepaint that always returns false is the
    // cheapest way to make the test above pass and the picker stop working.
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: ChatBackdrop(theme: velvet),
    ));
    final painter = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!;
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: ChatBackdrop(theme: dawn),
    ));
    final again = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!;
    expect(again.shouldRepaint(painter), isTrue,
        reason: 'switching theme must repaint, or the picker does nothing');
  });

  test('every built-in theme is covered by this widget', () {
    // chat_screen routes all six through ChatBackdrop; a seventh added later
    // with a shape this painter cannot draw would otherwise go unnoticed.
    for (final t in chatThemes) {
      expect(t.bg, isNotEmpty, reason: '${t.id} has no background colour');
    }
  });
}

const velvet = ChatTheme(
  id: 'velvet',
  name: 'Midnight Boudoir',
  bg: [Color(0xFF1A0E16), Color(0xFF2A1320)],
  myBubble: Color(0xFFC97B92),
  partnerBubble: Color(0xFF2E2230),
  text: Color(0xFFF7ECE4),
  subtext: Color(0xFFB59CA8),
);

const dawn = ChatTheme(
  id: 'dawn',
  name: 'Dawn',
  bg: [Color(0xFFF5E6DC), Color(0xFFEAD3CB)],
  myBubble: Color(0xFFE0A0B0),
  partnerBubble: Color(0xFFFFFFFF),
  text: Color(0xFF3A2030),
  subtext: Color(0xFF8A6B78),
);
