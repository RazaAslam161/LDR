import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/motion.dart';
import 'package:miles/core/ui/tab_dissolve.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_press.dart';
import 'package:miles/core/widgets/gilt_nav_icon.dart';

/// The foundations of the motion overhaul, pinned where they can regress
/// silently: the dissolve route transition, the tab fade-through, the press
/// acknowledgment, the nav selection — and for every one of them, the
/// animations-off contract: the finished screen, not a faster animation.
void main() {
  // One instance for the whole file: a fresh ThemeData per pump makes
  // MaterialApp's AnimatedTheme animate the "change" and leaves its ticker
  // in every transientCallbackCount assertion.
  final theme = milesDarkTheme();

  Widget appWith({required Widget home, bool animationsOff = false}) {
    // The disableAnimations override must be injected INSIDE MaterialApp:
    // WidgetsApp builds its own MediaQuery from the view, so an ambient one
    // wrapped around the app is silently discarded — a harness that wraps
    // outside tests nothing while looking like it tests the off() path.
    return MaterialApp(
      theme: theme,
      home: home,
      builder: !animationsOff
          ? null
          : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
    );
  }

  group('DissolveIn route transition', () {
    testWidgets('mid-push, the incoming page is fading up', (tester) async {
      await tester.pumpWidget(appWith(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('second')),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The incoming route renders through at least one partial FadeTransition
      // — the dissolve is actually installed app-wide via the theme, not the
      // framework's zoom default (which uses scale, not a fade+rise pair).
      final fades = tester
          .widgetList<FadeTransition>(find.byType(FadeTransition))
          .where((f) => f.opacity.value > 0 && f.opacity.value < 1);
      expect(fades, isNotEmpty,
          reason: 'mid-transition there must be a partial fade — the '
              'DissolveIn builder is not installed');
      expect(find.text('second'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('animations off = the pushed page arrives finished',
        (tester) async {
      await tester.pumpWidget(appWith(
        animationsOff: true,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('second')),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      // One frame to start the route, one for the transition's first frame.
      await tester.pump();
      await tester.pump();
      // Every FadeTransition wrapping the new route must already be at 1 —
      // the off() path returns the bare child, so any fade present is the
      // framework's own at rest.
      final partial = tester
          .widgetList<FadeTransition>(find.byType(FadeTransition))
          .where((f) => f.opacity.value > 0 && f.opacity.value < 1);
      expect(partial, isEmpty,
          reason: 'with animations disabled nothing may be mid-fade');
      expect(find.text('second'), findsOneWidget);
    });
  });

  group('TabDissolve', () {
    testWidgets('a tab flip fades through and settles clean', (tester) async {
      Widget shell(int index) => appWith(
            home: Scaffold(
              body: TabDissolve(
                index: index,
                child: Text('tab $index'),
              ),
            ),
          );
      await tester.pumpWidget(shell(0));
      expect(find.text('tab 0'), findsOneWidget);

      await tester.pumpWidget(shell(1));
      await tester.pump(const Duration(milliseconds: 60));
      // Mid-run both subtrees exist (the stack), and at least one is partial.
      expect(find.text('tab 1'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('tab 0'), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('animations off = the new tab is simply there', (tester) async {
      Widget shell(int index) => appWith(
            animationsOff: true,
            home: Scaffold(
              body: TabDissolve(index: index, child: Text('tab $index')),
            ),
          );
      await tester.pumpWidget(shell(0));
      await tester.pumpWidget(shell(1));
      await tester.pump();
      expect(find.text('tab 1'), findsOneWidget);
      expect(find.text('tab 0'), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    });
  });

  group('EmberPress', () {
    testWidgets('contact scales to pressedScale and release recovers',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(appWith(
        home: Scaffold(
          body: Center(
            child: EmberPress(
              onTap: () => taps++,
              child: const SizedBox(width: 80, height: 40, child: Text('go')),
            ),
          ),
        ),
      ));

      final gesture =
          await tester.startGesture(tester.getCenter(find.text('go')));
      // onTapDown only fires once the tap arena's press deadline (~100ms)
      // passes; the press animation starts THEN, so give it its own budget.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(MilesMotion.instant);
      // Two traps in one helper. ancestor() makes no ordering promise and the
      // hover AnimatedScale contributes a second (identity) Transform, so the
      // press is the SMALLEST scale on the chain. And that scale is read from
      // storage[0] (the X axis): Transform.scale builds diagonal(s, s, 1.0),
      // so getMaxScaleOnAxis() returns the untouched Z — 1.0 — for every
      // uniform 2D shrink. A ruler that cannot see the thing it measures.
      double minScale() => tester
          .widgetList<Transform>(find.ancestor(
            of: find.text('go'),
            matching: find.byType(Transform),
          ))
          .map((t) => t.transform.storage[0])
          .reduce((a, b) => a < b ? a : b);
      expect(minScale(), closeTo(0.97, 0.005),
          reason: 'the press acknowledgment is scale 0.97');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(minScale(), closeTo(1.0, 0.001));
      expect(taps, 1);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('animations off = identity transform, tap still lands',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(appWith(
        animationsOff: true,
        home: Scaffold(
          body: Center(
            child: EmberPress(
              onTap: () => taps++,
              child: const SizedBox(width: 80, height: 40, child: Text('go')),
            ),
          ),
        ),
      ));
      final gesture =
          await tester.startGesture(tester.getCenter(find.text('go')));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(MilesMotion.instant);
      final scales = tester
          .widgetList<Transform>(find.ancestor(
            of: find.text('go'),
            matching: find.byType(Transform),
          ))
          .map((t) => t.transform.storage[0]);
      expect(scales.every((s) => s == 1.0), isTrue,
          reason: 'off() means the child never scales');
      await gesture.up();
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('GiltNavIcon', () {
    testWidgets('selection cross-fades the layers and the ring dies away',
        (tester) async {
      Widget nav({required bool selected}) => appWith(
            home: Scaffold(
              body: Center(
                child: GiltNavIcon(
                  icon: const Icon(Icons.circle_outlined),
                  selectedIcon: const Icon(Icons.circle),
                  selected: selected,
                ),
              ),
            ),
          );
      await tester.pumpWidget(nav(selected: false));
      await tester.pumpWidget(nav(selected: true));
      await tester.pump(const Duration(milliseconds: 120));
      // Mid-run: the bloom ring is on screen.
      expect(
        find.descendant(
          of: find.byType(GiltNavIcon),
          matching: find.byType(Container),
        ),
        findsOneWidget,
        reason: 'the gilt ring blooms during selection',
      );
      await tester.pumpAndSettle();
      // Settled: ring gone, selected layer fully in.
      expect(
        find.descendant(
          of: find.byType(GiltNavIcon),
          matching: find.byType(Container),
        ),
        findsNothing,
        reason: 'the ring is one-shot; nothing may keep painting',
      );
      expect(tester.binding.transientCallbackCount, 0);
    });
  });
}
