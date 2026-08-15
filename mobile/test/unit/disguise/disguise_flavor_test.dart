import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/disguise_picker_screen.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The disguise is a build-channel decision, and getting it backwards is a
/// shipping incident either way round: the play channel opening on a fake news
/// reader under an honest icon is the Deceptive Behavior finding it exists to
/// avoid, and a sideload build that stops covering itself exposes every user of
/// the only channel that actually ships.
///
/// So both directions are asserted here, not just the new one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('miles/disguise');

  void mockChannel(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    DisguiseService.enabled = true;
    MilesApp.showRealApp.value = false;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    DisguiseService.enabled = true;
  });

  test('the channel answer is what decides it', () async {
    mockChannel((c) async => c.method == 'isEnabled' ? false : null);
    await DisguiseService.loadEnabled();
    expect(DisguiseService.enabled, isFalse);
  });

  test('a channel that throws keeps the disguise', () async {
    mockChannel((_) async => throw PlatformException(code: 'boom'));
    await DisguiseService.loadEnabled();
    expect(DisguiseService.enabled, isTrue);
  });

  test('a channel that never answers keeps the disguise', () async {
    // Cold-start path: this is awaited before runApp, so it must come back on
    // its own. Defaulting the other way would strip a sideloaded phone's cover
    // over a platform hiccup.
    mockChannel((_) => Completer<Object?>().future);
    await DisguiseService.loadEnabled();
    expect(DisguiseService.enabled, isTrue);
  });

  test('raiseCover covers a sideload build', () {
    MilesApp.showRealApp.value = true;
    MilesApp.raiseCover();
    expect(MilesApp.showRealApp.value, isFalse);
  });

  test('raiseCover cannot cover a play build', () {
    // Every path that hides the app goes through here — backgrounding, the
    // panic gestures, sign-out. On a build with no cover to raise, lowering the
    // flag would put a fake news reader in front of an honestly-named app.
    DisguiseService.enabled = false;
    MilesApp.showRealApp.value = true;
    MilesApp.raiseCover();
    expect(MilesApp.showRealApp.value, isTrue);
  });

  test('the onboarding prompt has nothing to ask on a play build', () async {
    DisguiseService.enabled = false;
    expect(await DisguiseService.hasChosen(), isTrue);
    DisguiseService.enabled = true;
    expect(await DisguiseService.hasChosen(), isFalse);
  });

  testWidgets('the picker offers no identity on a play build', (tester) async {
    // Settings links here on every channel, so the screen itself has to refuse.
    DisguiseService.enabled = false;
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: DisguisePickerScreen()),
    ),);
    await tester.pump();

    expect(find.text('Use this disguise'), findsNothing);
    for (final label in const ['Calculator', 'Notes', 'Weather']) {
      expect(find.text(label), findsNothing,
          reason: '$label is offered inside the honestly-named build',);
    }
  });

  testWidgets('the picker is untouched on a sideload build', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: DisguisePickerScreen()),
    ),);
    await tester.pump();

    expect(find.text('Use this disguise'), findsOneWidget);
    expect(find.text('Calculator'), findsOneWidget);
  });
}
