import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/ui/theme.dart';

/// Fourth sweep at the frosted-glass look, and the first one to look at
/// dialogs, sheets and menus.
///
/// The three static sweeps before this read `lib/**` for a translucent colour
/// spelled out in source, and all three went green while the owner was still
/// watching the ember field animate behind "Delete for everyone". They could
/// not have found it, because the glass here is in what is NOT written:
///
///   * `ColorScheme.dark(surface: Colors.transparent)` set the app's surface
///     role. In ColorScheme, `surfaceContainer`, `surfaceContainerLow` and
///     `surfaceContainerHigh` are each `?? surface` — and those three are the
///     M3 defaults for menus, sheets and dialogs. A dialog naming no colour at
///     all therefore painted nothing at all.
///   * `Colors.transparent` at a call site is not a spelling any of the
///     regexes knew. They matched `.withValues(alpha:`, `.withOpacity(`, an
///     ARGB literal and `Colors.black54`; the most transparent colour in
///     Material has none of those shapes.
///
/// So this stops reading source and measures pixels. Each surface is rendered
/// twice over two different backgrounds, and a pixel that moved between the
/// two renders is a pixel you can see the background through. That is the
/// thing itself rather than a proxy for it, so it costs nothing to a surface
/// that reaches opacity some other way — AppDrawer is a transparent [Drawer]
/// wrapping an opaque panel, and is not glass — and no rename can satisfy it.
void main() {
  // Building the theme builds its TextTheme, and every GoogleFonts style fires
  // an unawaited fetch the moment it is constructed. Off the device that fetch
  // cannot succeed, and the rejection surfaces as an unhandled async error in
  // whichever test happens to be running. So the theme is built exactly once,
  // here, and its pending fetches are awaited to failure where the failure
  // belongs. Fonts are not what these tests measure; the colour of a panel is.
  late final ThemeData theme;
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    // google_fonts chains a `.then` onto each fetch with no error handler, so
    // the rejection is unhandled by construction and cannot be awaited away.
    // It belongs to the zone the style was built in, which is the one thing
    // that can absorb it — so the theme is built once, inside a zone that
    // does.
    runZonedGuarded(
      () => theme = milesDarkTheme(),
      (_, __) {},
      zoneSpecification: ZoneSpecification(print: (_, __, ___, ____) {}),
    );
  });

  const behindA = Color(0xFF00FF00);
  const behindB = Color(0xFFFF00FF);

  /// Renders [tree] over [behind], runs [open], and returns the raw RGBA of
  /// the whole screen.
  Future<Uint8List> shoot(
    WidgetTester tester,
    Color behind,
    Widget Function() tree,
    Future<void> Function(WidgetTester) open,
  ) async {
    await tester.pumpWidget(RepaintBoundary(
      // Stands in for the ember field: the app's scaffold is transparent by
      // design so the animated background shows through a page.
      child: ColoredBox(
        color: behind,
        // Keyed on the background, so the second render replaces the tree
        // instead of reusing the Navigator — which would keep the route the
        // first render pushed and open the modal twice.
        child: KeyedSubtree(key: ValueKey(behind), child: tree()),
      ),
    ),);
    await open(tester);
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,);
    // Rasterising is real work on a real clock. Awaited under the test's fake
    // one, toImage() simply never completes.
    late final Uint8List pixels;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData();
      image.dispose();
      pixels = data!.buffer.asUint8List();
    });
    return pixels;
  }

  /// Fails if any pixel in the middle of [locate] differs between the two
  /// renders. The middle, not the whole rect: every one of these surfaces has
  /// rounded corners, and the background legitimately shows in the corners of
  /// their bounding box.
  Future<void> expectHidesBackground(
    WidgetTester tester,
    String what, {
    required Widget Function() tree,
    required Future<void> Function(WidgetTester) open,
    required Finder locate,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final a = await shoot(tester, behindA, tree, open);
    final rect = tester.getRect(locate);
    final b = await shoot(tester, behindB, tree, open);
    expect(tester.getRect(locate), rect, reason: '$what moved between renders');

    final width = tester.view.physicalSize.width ~/ 1;
    final inner = Rect.fromCenter(
      center: rect.center,
      width: rect.width / 2,
      height: rect.height / 2,
    );
    var seen = 0;
    for (var y = inner.top.ceil(); y < inner.bottom.floor(); y++) {
      for (var x = inner.left.ceil(); x < inner.right.floor(); x++) {
        final i = (y * width + x) * 4;
        if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) {
          fail('$what is see-through at ($x,$y): changing what sits behind it '
              'changed the pixel from ${a[i]},${a[i + 1]},${a[i + 2]} to '
              '${b[i]},${b[i + 1]},${b[i + 2]}. Behind it on this app is the '
              'animated ember field, which is what makes the surface read as '
              'frosted glass. Give it an opaque MilesColors fill.');
        }
        seen++;
      }
    }
    expect(seen, greaterThan(100), reason: '$what was too small to sample');
  }

  /// The app under its real theme, with an empty page to open modals from.
  Widget app({Widget? drawer, GlobalKey<ScaffoldMessengerState>? messenger}) =>
      MaterialApp(
        theme: theme,
        scaffoldMessengerKey: messenger,
        home: Scaffold(drawer: drawer, body: const SizedBox.expand()),
      );

  /// The [Material] that actually paints [surface]. Not the widget's own box:
  /// a [Dialog]'s render object spans the whole screen and only the Material
  /// inside it is the panel, so measuring the widget would sample the barrier
  /// and call every dialog glass.
  Finder painted(Type surface) => find
      .descendant(of: find.byType(surface), matching: find.byType(Material))
      .first;

  /// Opens a route from the page's own context, which is what a modal needs.
  Future<void> Function(WidgetTester) route(void Function(BuildContext) open) =>
      (tester) async {
        open(tester.element(find.byType(SizedBox).first));
        await tester.pumpAndSettle();
      };

  testWidgets('a dialog hides what is behind it', (tester) async {
    await expectHidesBackground(
      tester,
      'AlertDialog',
      tree: app,
      open: route((c) => showDialog<void>(
            context: c,
            builder: (_) => AlertDialog(
              title: const Text('Clear conversation?'),
              content: const Text('This cannot be undone.'),
              actions: [
                TextButton(onPressed: () {}, child: const Text('Cancel')),
              ],
            ),
          ),),
      locate: painted(Dialog),
    );
  });

  testWidgets('a bottom sheet hides what is behind it', (tester) async {
    await expectHidesBackground(
      tester,
      'bottom sheet',
      tree: app,
      open: route((c) => showModalBottomSheet<void>(
            context: c,
            builder: (_) => const SizedBox(
              height: 220,
              child: Center(child: Text('Delete for everyone')),
            ),
          ),),
      locate: painted(BottomSheet),
    );
  });

  testWidgets('a menu hides what is behind it', (tester) async {
    await expectHidesBackground(
      tester,
      'showMenu',
      tree: app,
      open: route((c) => showMenu<int>(
            context: c,
            position: const RelativeRect.fromLTRB(40, 140, 40, 140),
            items: const [
              PopupMenuItem(value: 1, child: Text('Delete for everyone')),
              PopupMenuItem(value: 2, child: Text('Delete for me')),
              PopupMenuItem(value: 3, child: Text('Copy')),
            ],
          ),),
      locate:
          find.ancestor(of: find.text('Copy'), matching: find.byType(Material))
              .last,
    );
  });

  testWidgets('a drawer hides what is behind it', (tester) async {
    await expectHidesBackground(
      tester,
      'Drawer',
      tree: () =>
          app(drawer: const Drawer(child: Center(child: Text('Settings')))),
      open: (tester) async {
        Scaffold.of(tester.element(find.byType(SizedBox).first)).openDrawer();
        await tester.pumpAndSettle();
      },
      locate: painted(Drawer),
    );
  });

  testWidgets('a snack bar hides what is behind it', (tester) async {
    final messenger = GlobalKey<ScaffoldMessengerState>();
    await expectHidesBackground(
      tester,
      'SnackBar',
      tree: () => app(messenger: messenger),
      open: (tester) async {
        messenger.currentState!
            .showSnackBar(const SnackBar(content: Text('Saved to the vault')));
        await tester.pumpAndSettle();
      },
      locate: painted(SnackBar),
    );
  });

  test('no modal surface is left to M3 to tint by elevation', () {
    // The other half of the M3 default, and the reason a surface can be fully
    // opaque and still read as frosted: Material blends `surfaceTint` into the
    // fill in proportion to elevation. It is a second colour nobody in this
    // design system chose, and on a dark palette it lifts a plum panel towards
    // a pale wash the higher it floats. Setting it transparent is how M3 is
    // told the fill is the fill.
    final t = theme;
    final unset = <String>[
      if (t.dialogTheme.surfaceTintColor?.a != 0.0) 'dialogTheme',
      if (t.bottomSheetTheme.surfaceTintColor?.a != 0.0) 'bottomSheetTheme',
      if (t.popupMenuTheme.surfaceTintColor?.a != 0.0) 'popupMenuTheme',
      if (t.drawerTheme.surfaceTintColor?.a != 0.0) 'drawerTheme',
      if (t.cardTheme.surfaceTintColor?.a != 0.0) 'cardTheme',
      if (t.appBarTheme.surfaceTintColor?.a != 0.0) 'appBarTheme',
      if (t.navigationBarTheme.surfaceTintColor?.a != 0.0) 'navigationBarTheme',
      if (t.menuTheme.style?.surfaceTintColor?.resolve({})?.a != 0.0)
        'menuTheme',
      if (t.dropdownMenuTheme.menuStyle?.surfaceTintColor?.resolve({})?.a != 0.0)
        'dropdownMenuTheme',
    ];
    expect(unset, isEmpty,
        reason: 'surfaceTintColor is unset, so M3 tints these by elevation: '
            '$unset',);
  });

  test('the surface roles a modal falls back to are opaque', () {
    // ColorScheme resolves surfaceContainer/Low/High as `?? surface`, and
    // those are the M3 defaults behind a menu, a sheet and a dialog. Setting
    // `surface: Colors.transparent` so the ember field could show through a
    // page therefore made every unstyled modal in the app invisible — one
    // line, nowhere near any of them. A page gets its transparency from
    // scaffoldBackgroundColor instead, which no modal reads.
    final c = theme.colorScheme;
    final seeThrough = {
      'surface': c.surface,
      'surfaceContainerLowest': c.surfaceContainerLowest,
      'surfaceContainerLow': c.surfaceContainerLow,
      'surfaceContainer': c.surfaceContainer,
      'surfaceContainerHigh': c.surfaceContainerHigh,
      'surfaceContainerHighest': c.surfaceContainerHighest,
      'inverseSurface': c.inverseSurface,
    }..removeWhere((_, v) => v.a == 1.0);
    expect(seeThrough, isEmpty,
        reason: 'a modal that names no colour falls back to these: '
            '$seeThrough',);
  });
}
