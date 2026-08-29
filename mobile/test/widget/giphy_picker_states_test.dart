import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/giphy_service.dart';
import 'package:miles/features/chat/widgets/giphy_picker.dart';

/// Pumps the sheet directly (not via showModalBottomSheet) with a canned
/// outcome, so every failure class GIPHY can hand back is reachable without a
/// live call.
///
/// Explicit pumps rather than pumpAndSettle: the in-flight state is a
/// CircularProgressIndicator, which never settles.
Future<void> _pump(
  WidgetTester tester,
  Future<GiphyResult> Function(String) loader,
) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: GiphySheet(loader: loader))),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('an outage does not read as a search that matched nothing',
      (tester) async {
    await _pump(
      tester,
      (_) async => const GiphyResult(GiphyStatus.unavailable),
    );

    // The defect: every failure came back as an empty list, so a revoked key,
    // a spent quota and a phone with no signal all told the user their word
    // was the problem — on the opening trending load, before they typed one.
    expect(find.textContaining('No GIFs found'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a missing key is its own state, and offers no dead retry',
      (tester) async {
    await _pump(
      tester,
      (_) async => const GiphyResult(GiphyStatus.notConfigured),
    );

    expect(find.textContaining('GIPHY key'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('an empty trending load blames no word the user never typed',
      (tester) async {
    await _pump(tester, (_) async => const GiphyResult(GiphyStatus.ok));

    expect(find.textContaining('No GIFs found'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('an empty SEARCH is the one case that says try another word',
      (tester) async {
    await _pump(tester, (_) async => const GiphyResult(GiphyStatus.ok));
    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pump(const Duration(milliseconds: 500)); // past the debounce
    await tester.pump();

    expect(find.textContaining('No GIFs found'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('retry re-runs the query that failed, not trending',
      (tester) async {
    final asked = <String>[];
    await _pump(tester, (q) async {
      asked.add(q);
      return const GiphyResult(GiphyStatus.unavailable);
    });
    await tester.enterText(find.byType(TextField), 'cats');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();

    expect(asked, ['', 'cats', 'cats']);
  });
}
