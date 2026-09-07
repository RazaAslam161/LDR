import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ui/content_language.dart';
import 'package:miles/core/widgets/language_toggle.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The switch is the only way back to English for a user who cannot read Roman
/// Urdu, so "it flips and it sticks" is not a detail.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: LanguageToggle())),
        ),
      ),
    );
    return container;
  }

  testWidgets('shows both languages, so there is visibly one to switch to',
      (tester) async {
    await pump(tester);
    expect(find.text('EN'), findsOneWidget);
    expect(find.text('UR'), findsOneWidget);
  });

  testWidgets('stays its own size in a slot that offers it the whole row',
      (tester) async {
    // It ships in a ListTile's trailing, where the constraints are bounded.
    // An unsized Align inside took every pixel offered, so on device the pill
    // spanned the entire row and crushed the label beside it to one letter per
    // line.
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ListTile(
              title: const Text('Content language'),
              subtitle: const Text('Game prompts and dares are in English'),
              trailing: const LanguageToggle(padding: EdgeInsets.zero),
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final width = tester.getSize(find.byType(LanguageToggle)).width;
    expect(width, lessThan(100), reason: 'the pill swallowed the row');
    // And the row's own text still gets a sane share of the width.
    expect(tester.getSize(find.text('Content language')).width,
        greaterThan(100),);
  });

  testWidgets('starts in English', (tester) async {
    final container = await pump(tester);
    expect(container.read(contentLanguageProvider), ContentLanguage.english);
  });

  testWidgets('a tap flips it, and another flips it back', (tester) async {
    final container = await pump(tester);

    await tester.tap(find.byType(LanguageToggle));
    await tester.pumpAndSettle();
    expect(container.read(contentLanguageProvider), ContentLanguage.romanUrdu);

    await tester.tap(find.byType(LanguageToggle));
    await tester.pumpAndSettle();
    expect(container.read(contentLanguageProvider), ContentLanguage.english);
  });

  testWidgets('the choice survives a restart', (tester) async {
    final first = await pump(tester);
    await tester.tap(find.byType(LanguageToggle));
    await tester.pumpAndSettle();
    expect(first.read(contentLanguageProvider), ContentLanguage.romanUrdu);

    // A fresh container is a fresh launch: nothing in memory, only disk.
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    restarted.read(contentLanguageProvider);
    await tester.pumpAndSettle();
    expect(restarted.read(contentLanguageProvider), ContentLanguage.romanUrdu);
  });

  testWidgets('an unreadable stored value falls back to English',
      (tester) async {
    // A downgrade, or a language that no longer exists, must not leave the app
    // in a state the user cannot read their way out of.
    SharedPreferences.setMockInitialValues({'content_language': 'klingon'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(contentLanguageProvider);
    await tester.pumpAndSettle();
    expect(container.read(contentLanguageProvider), ContentLanguage.english);
  });

  test('the settings row says which language the toggle holds', () {
    // The row was a const with 'Games in English' baked in, one line above
    // the toggle that changes it. Source-law: the settings screen cannot be
    // pumped (about_links_a11y_test.dart documents the wall).
    final settings =
        File('lib/features/settings/settings_screen.dart').readAsStringSync();
    final at = settings.indexOf("title: 'Content language'");
    expect(at, greaterThan(0));
    final row = settings.substring(at, at + 300);
    expect(row, isNot(contains("'Games in English'")));
    expect(row, contains('contentLanguageProvider'));
  });
}
