import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/safety/severance_sheet.dart';

/// The sheet that starts the unlinking ritual, RENDERED.
///
/// It was never rendered in a test before, and it shipped with its primary
/// action off the right edge of a 360dp phone: the actions Row overflowed, the
/// Spacer collapsed to zero, and "Begin" — the only control that starts the
/// ceremony — was laid out past the screen where no pointer can reach it. In a
/// release build a RenderFlex overflow paints nothing and logs nothing, so the
/// symptom was "I press End the connection and nothing happens".
///
/// Same class as the audit CRITICAL that /unlink already carries a law for
/// (§194): the one control that matters, pushed out of reach.
void main() {
  const phone = Size(360, 800);

  Future<void> openSheet(
    WidgetTester tester, {
    double textScale = 1.0,
    bool hasPartner = true,
  }) async {
    await tester.binding.setSurfaceSize(phone);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: milesDarkTheme(),
        home: MediaQuery(
          data: MediaQueryData(
            size: phone,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showSeveranceSheet(
                    context,
                    onStartCeremony: () async {},
                    hasPartner: hasPartner,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('the ceremony sheet', () {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('Begin is on screen and tappable at text scale $scale',
          (tester) async {
        await openSheet(tester, textScale: scale);
        await tester.tap(find.text('End the connection'));
        await tester.pumpAndSettle();

        final begin = find.widgetWithText(FilledButton, 'Begin');
        expect(begin, findsOneWidget,
            reason: 'nothing starts the ceremony without it',);

        final box = tester.getRect(begin);
        expect(box.right, lessThanOrEqualTo(phone.width),
            reason: 'Begin is off the right edge — the actions Row overflowed, '
                'and in a release build that is silent. This is the bug that '
                'made End the connection do nothing.',);
        expect(box.left, greaterThanOrEqualTo(0));
        expect(box.bottom, lessThanOrEqualTo(phone.height));

        await tester.tap(begin);
        await tester.pumpAndSettle();
      });
    }

    testWidgets('the copy matches the server: one day, never a week',
        (tester) async {
      // The sheet is read at the moment of decision. 20260830120000 sets
      // cooling_ends_at to now() + 24 hours; a sheet still promising a week is
      // the app lying where it can least afford to.
      await openSheet(tester);
      await tester.tap(find.text('End the connection'));
      await tester.pumpAndSettle();

      final words = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ')
          .toLowerCase();
      for (final stale in ['week', 'seven day', 'seven-day']) {
        expect(words.contains(stale), isFalse,
            reason: 'the ceremony sheet still says "$stale"',);
      }
    });
  });

  testWidgets('a couple of one is offered the plain exit, not the ritual',
      (tester) async {
    // unlink_start() raises no_partner, so offering the ceremony row to
    // somebody with nobody on the other side is offering a dead control.
    await openSheet(tester, hasPartner: false);
    expect(find.text('End the connection'), findsNothing);
    expect(find.text('Leave this connection'), findsOneWidget);
  });
}
