import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';

/// Counts the opaque `night` fill each painting EmberBackground lays down —
/// a proxy for "how many backdrops are actually running".
int _backdrops(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(find.byType(DecoratedBox))
    .where((d) =>
        d.decoration is BoxDecoration &&
        (d.decoration as BoxDecoration).color == MilesColors.night,)
    .length;

void main() {
  testWidgets('paints the backdrop when nothing above it does', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: EmberBackground(child: SizedBox.shrink())),
    );
    expect(_backdrops(tester), 1);
  });

  testWidgets('nested instances collapse to a single backdrop', (tester) async {
    // main.dart mounts one app-wide and 12 screens wrap themselves in another.
    // The inner opaque fill hid the outer one, so the outer was repainting
    // every vsync for pixels nobody could see.
    await tester.pumpWidget(
      const MaterialApp(
        home: EmberBackground(
          child: EmberBackground(
            child: EmberBackground(child: SizedBox.shrink()),
          ),
        ),
      ),
    );
    expect(_backdrops(tester), 1);
  });

  testWidgets('the child still renders when nested', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: EmberBackground(
          child: EmberBackground(child: Text('hello', textDirection: TextDirection.ltr)),
        ),
      ),
    );
    expect(find.text('hello'), findsOneWidget);
  });
}
