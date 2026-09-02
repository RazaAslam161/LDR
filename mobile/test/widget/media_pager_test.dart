import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/widgets/media_viewer.dart';
import 'package:miles/features/profile/shared_media_window.dart';

/// The bug this whole screen was rebuilt for: open the third photo from the
/// profile grid and you could not reach the fourth. Every photo cost a close
/// and a re-open.
///
/// Nothing here is seeded into MediaUrls, so every page resolves to its failed
/// state and no image is ever fetched. That is deliberate: what is under test
/// is the pager — which item is showing, how far the window reaches, and who
/// owns the horizontal drag — and none of that should depend on a signature
/// or on bytes arriving.
void main() {
  // The failed state on purpose (see the file comment), without the throw
  // that used to reach ErrorReporter for every page the pager warmed.
  setUp(() => MediaUrls.signForTest = (_, __) async => null);
  tearDown(() => MediaUrls.signForTest = null);

  Message photo(int seq) => Message(
        id: 'm$seq',
        senderId: 'them',
        createdAt: DateTime(2026),
        kind: 'image',
        imagePath: 'couple/img_$seq.jpg',
        seq: seq,
      );

  /// A shelf of [count] photos that is already at its end.
  SharedMediaWindow closedWindow(int count) => SharedMediaWindow(
        fetch: (_) async => [for (var i = count; i > 0; i--) photo(i)],
        pageSize: count + 1,
        partnerName: 'Ana',
        myUid: 'me',
      );

  /// A point on the page itself, clear of the chrome at the top and of the
  /// retry button each unresolved page centres on.
  Offset onThePage(WidgetTester tester) {
    final centre = tester.getCenter(find.byType(PageView));
    return Offset(centre.dx, centre.dy - 150);
  }

  Future<void> pumpViewer(WidgetTester tester, SharedMediaWindow window,
      {int index = 0,}) async {
    await window.more();
    await tester.pumpWidget(
      MaterialApp(home: MediaViewer(source: window, initialIndex: index)),
    );
    await tester.pump();
  }

  testWidgets('it opens on the item that was tapped, not on the first',
      (tester) async {
    await pumpViewer(tester, closedWindow(6), index: 3);
    expect(find.text('4 of 6'), findsOneWidget);
  });

  testWidgets('the next photo is one swipe away', (tester) async {
    // The complaint, exactly.
    await pumpViewer(tester, closedWindow(6), index: 2);
    expect(find.text('3 of 6'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('4 of 6'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(find.text('3 of 6'), findsOneWidget);
  });

  testWidgets('only three pages are alive however far in you are',
      (tester) async {
    // PageView.builder plus allowImplicitScrolling: exactly one page either
    // side is built and everything else is torn down. Materialised children
    // would hold all sixty of these, and five thousand on a real shelf — the
    // fiftieth swipe is where a naive pager gets the process killed.
    await pumpViewer(tester, closedWindow(60), index: 30);

    expect(
        tester.widget<PageView>(find.byType(PageView)).allowImplicitScrolling,
        isTrue,);
    // One InteractiveViewer per photo page: the one on screen and its two
    // neighbours, never the other fifty-seven.
    expect(find.byType(InteractiveViewer, skipOffstage: false), findsNWidgets(3));
  });

  testWidgets('reaching the end of the loaded window loads more of it',
      (tester) async {
    // The window is what bounds the pager, so a pager that cannot make it grow
    // stops dead at whatever the grid happened to have.
    var pages = 0;
    final window = SharedMediaWindow(
      fetch: (beforeSeq) async {
        pages++;
        final from = beforeSeq ?? 100;
        return [for (var i = 1; i <= 10; i++) photo(from - i)];
      },
      pageSize: 10,
      partnerName: 'Ana',
      myUid: 'me',
    );

    // Index 5 of 10 is inside the look-ahead, so opening there is already a
    // request — the window extends before the swipe that would need it.
    await pumpViewer(tester, window, index: 5);
    await tester.pumpAndSettle();

    expect(pages, 2);
    expect(find.text('6 of 20'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('7 of 20'), findsOneWidget);
  });

  testWidgets('a tap moves the chrome, it does not close the viewer',
      (tester) async {
    // The old viewer wrapped everything in onTap: maybePop. In a pager,
    // tapping to get the caption out of the way threw you back to the grid.
    await pumpViewer(tester, closedWindow(6), index: 1);
    AnimatedOpacity chrome() => tester.widget<AnimatedOpacity>(find.ancestor(
        of: find.text('2 of 6'), matching: find.byType(AnimatedOpacity),),);
    expect(chrome().opacity, 1);

    await tester.tapAt(onThePage(tester));
    // The accepted cost of having a double-tap recogniser at all: the single
    // tap cannot resolve until the double-tap window has closed.
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();

    expect(find.byType(MediaViewer), findsOneWidget);
    expect(chrome().opacity, 0);
    expect(find.text('2 of 6'), findsOneWidget);
  });

  testWidgets('zoomed in, the drag pans the photo instead of turning the page',
      (tester) async {
    // Left to the gesture arena this is broken on the first zoom: Scrollable's
    // horizontal drag claims the pointer at 18px of movement and
    // InteractiveViewer's scale gesture only at 36px, so the pager wins every
    // single-finger pan. The fix is not to race it — zoomed in, the pager has
    // no physics to drag with.
    await pumpViewer(tester, closedWindow(6), index: 2);
    expect(tester.widget<PageView>(find.byType(PageView)).physics,
        isA<PageScrollPhysics>(),);

    final spot = onThePage(tester);
    await tester.tapAt(spot);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(spot);
    await tester.pumpAndSettle();

    expect(tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),);

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('3 of 6'), findsOneWidget);
  });

  testWidgets('a page change puts the zoom back', (tester) async {
    // Landing on the next photo already at 2.5x on some corner of it is the
    // tell of a hand-rolled viewer.
    await pumpViewer(tester, closedWindow(6), index: 2);
    final spot = onThePage(tester);
    await tester.tapAt(spot);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(spot);
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(find.byType(PageView)).physics,
        isA<NeverScrollableScrollPhysics>(),);

    // While zoomed there is deliberately no gesture that can turn the page, so
    // drive the controller the way an arrow key or a deep link would.
    final controller =
        tester.widget<PageView>(find.byType(PageView)).controller!;
    // Not awaited: the animation only advances when the tester pumps, so
    // awaiting it here waits for frames the await itself is preventing.
    unawaited(controller.animateToPage(3,
        duration: const Duration(milliseconds: 200), curve: Curves.linear,),);
    await tester.pumpAndSettle();

    expect(find.text('4 of 6'), findsOneWidget);
    expect(tester.widget<PageView>(find.byType(PageView)).physics,
        isA<PageScrollPhysics>(),);
  });
}
