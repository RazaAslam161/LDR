import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/call_face_strip.dart';

/// The strip the owner asked for by name: mini previews that are actually
/// scrollable, on a screen where a fixed column of tiles was the complaint.
/// FaceStrip takes plain widgets precisely so this test can exist —
/// RTCVideoView needs the platform channel and can only be judged on device.
void main() {
  Widget strip(int tiles) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FaceStrip(
              tiles: [
                for (var i = 0; i < tiles; i++)
                  SizedBox(
                    key: ValueKey('tile-$i'),
                    width: 110,
                    height: 150,
                  ),
              ],
            ),
          ),
        ),
      );

  testWidgets('two tiles fit a narrow phone with no overflow', (t) async {
    await t.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(strip(2));
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('tile-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('tile-1')), findsOneWidget);
  });

  testWidgets('the strip scrolls smoothly past what fits', (t) async {
    await t.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(strip(5));
    expect(t.takeException(), isNull);

    final list = find.byType(ListView);
    final scrollable = t.widget<ListView>(list);
    expect(scrollable.scrollDirection, Axis.horizontal);
    expect(scrollable.physics, isA<BouncingScrollPhysics>());

    // Five 110dp tiles + gaps cannot fit 320dp: the last tile starts
    // offscreen and dragging brings it in — the "smooth scrollable" the
    // fixed column never was.
    expect(find.byKey(const ValueKey('tile-4'), skipOffstage: false),
        findsOneWidget,);
    final before = t.getTopLeft(
        find.byKey(const ValueKey('tile-0'), skipOffstage: false),);
    await t.drag(list, const Offset(-200, 0));
    await t.pumpAndSettle();
    final after = t.getTopLeft(
        find.byKey(const ValueKey('tile-0'), skipOffstage: false),);
    expect(after.dx, lessThan(before.dx));
  });
}
