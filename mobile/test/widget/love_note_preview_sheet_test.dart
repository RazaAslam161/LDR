import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/cycle/love_note_preview_sheet.dart';

/// Pumps the sheet directly (not via showModalBottomSheet) so the test drives
/// the widget under test rather than the sheet route.
Future<void> _pump(
  WidgetTester tester, {
  required String template,
  required String name,
  required Future<String?> Function() onChangeName,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LoveNotePreviewSheet(
          template: template,
          recipientName: name,
          onRegenerate: () {},
          onChangeName: onChangeName,
          onSend: (_) async {},
        ),
      ),
    ),
  );
}

String _body(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  const template = '{name}, tussi meri duniya ho';

  testWidgets('renders the name into the note on open', (tester) async {
    await _pump(tester,
        template: template, name: 'Aisha', onChangeName: () async => null);
    expect(_body(tester), 'Aisha, tussi meri duniya ho');
    expect(find.textContaining('For Aisha'), findsOneWidget);
  });

  testWidgets('backing out of the rename keeps the note and his edits',
      (tester) async {
    await _pump(tester,
        template: template, name: 'Aisha', onChangeName: () async => null);
    await tester.enterText(find.byType(TextField), 'Aisha, I WROTE THIS');
    await tester.tap(find.text('Change name'));
    await tester.pumpAndSettle();

    expect(_body(tester), 'Aisha, I WROTE THIS');
    expect(find.textContaining('For Aisha'), findsOneWidget);
  });

  testWidgets('renaming swaps the name in place and keeps his edits',
      (tester) async {
    await _pump(tester,
        template: template, name: 'Aisha', onChangeName: () async => 'Sara');
    await tester.enterText(find.byType(TextField), 'Aisha, I WROTE THIS');
    await tester.tap(find.text('Change name'));
    await tester.pumpAndSettle();

    expect(_body(tester), 'Sara, I WROTE THIS');
    expect(find.textContaining('For Sara'), findsOneWidget);
  });

  testWidgets(
      'renaming after he deleted her name re-renders, so the body can never '
      'disagree with the header', (tester) async {
    await _pump(tester,
        template: template, name: 'Aisha', onChangeName: () async => 'Sara');
    await tester.enterText(find.byType(TextField), 'Meri jaan, tussi meri duniya ho');
    await tester.tap(find.text('Change name'));
    await tester.pumpAndSettle();

    expect(_body(tester), contains('Sara'));
    expect(find.textContaining('For Sara'), findsOneWidget);
  });

  testWidgets('a note with no placeholder keeps his edits on rename',
      (tester) async {
    await _pump(tester,
        template: 'aap bohot pyaari ho',
        name: 'Aisha',
        onChangeName: () async => 'Sara');
    await tester.enterText(find.byType(TextField), 'aap bohot pyaari ho — EDITED');
    await tester.tap(find.text('Change name'));
    await tester.pumpAndSettle();

    expect(_body(tester), 'aap bohot pyaari ho — EDITED');
  });
}
