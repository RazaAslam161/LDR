import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/covers/news_cover_screen.dart';
import 'package:miles/features/disguise/disguise_cover_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The cover screen is the first thing a user sees on every cold start. If
/// anything it awaits can hang, the app shows a blank rectangle with no way
/// forward — which is what "re-opens and sticks on this page" looked like.
///
/// These assert on the widget TREE rather than pixels: the covers do real work
/// (RSS, images) that a headless test cannot complete, so layout/network noise
/// is drained with takeException. What matters is that a cover is mounted at
/// all, in every failure mode.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('miles/disguise');

  void mockChannel(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpHost(WidgetTester tester) async {
    // A realistic phone surface; the default 800x600 makes the covers overflow.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(home: DisguiseCoverHost(onAuthenticated: () {})),
    );
  }

  /// A cover is mounted. Drains rendering/network noise the covers produce
  /// headlessly — we are asserting reachability, not paint.
  void expectCoverMounted(WidgetTester tester, {required String when}) {
    tester.takeException();
    expect(find.byType(NewsCoverScreen), findsOneWidget,
        reason: 'no cover mounted $when — the user would be stuck on a blank '
            'screen with no way into the app',);
  }

  testWidgets('mounts a cover when the platform channel never answers',
      (tester) async {
    // The exact failure that stranded users: an await that never completes.
    mockChannel((_) => Completer<Object?>().future);

    await pumpHost(tester);
    await tester.pump(const Duration(seconds: 5)); // past every timeout

    expectCoverMounted(tester, when: 'when the channel hangs');
  });

  testWidgets('mounts a cover when the channel throws', (tester) async {
    mockChannel((_) async => throw PlatformException(code: 'boom'));

    await pumpHost(tester);
    await tester.pump(const Duration(seconds: 5));

    expectCoverMounted(tester, when: 'when the channel throws');
  });

  testWidgets('mounts a cover on the very first frame', (tester) async {
    mockChannel((_) async => 'News');

    await pumpHost(tester);
    await tester.pump(); // first frame only, before any async resolves

    // The old code rendered a bare ColoredBox here, so a slow disk read
    // surfaced as a blank screen.
    expectCoverMounted(tester, when: 'on the first frame');
  });

  group('the in-cover unread dot', () {
    // Covers post no notification at all (the shade header would say
    // "Miles"), so this dot is the ONLY unread signal a disguised user gets.
    const dot = ValueKey('coverUnreadDot');

    testWidgets('shows when a background push left unread waiting',
        (tester) async {
      mockChannel((_) async => 'News');
      SharedPreferences.setMockInitialValues({
        'active_couple_id': 'c-1',
        'miles_unread_c-1': 3,
      });

      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 5));

      tester.takeException();
      expect(find.byKey(dot), findsOneWidget,
          reason: 'unread behind a cover must surface somewhere, and the '
              'cover UI is the only place the OS cannot relabel',);
    });

    testWidgets('absent when nothing is unread', (tester) async {
      mockChannel((_) async => 'News');
      SharedPreferences.setMockInitialValues({'active_couple_id': 'c-1'});

      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 5));

      tester.takeException();
      expect(find.byKey(dot), findsNothing);
    });

    testWidgets('absent when signed out, even over a stale tally',
        (tester) async {
      // No active_couple_id: the previous account's tally must not put a
      // signal on the next person's cover.
      mockChannel((_) async => 'News');
      SharedPreferences.setMockInitialValues({'miles_unread_c-1': 3});

      await pumpHost(tester);
      await tester.pump(const Duration(seconds: 5));

      tester.takeException();
      expect(find.byKey(dot), findsNothing);
    });
  });
}
