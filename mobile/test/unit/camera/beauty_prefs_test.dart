import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/camera/beauty/beauty_prefs.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The stored defaults, and the two questions a persistence layer must answer
/// honestly: what a fresh install gets, and what a corrupt document gets.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BeautyPrefs.debugReset();
  });

  tearDown(BeautyPrefs.debugReset);

  test('a fresh install is off, with calls opted in behind it', () async {
    await BeautyPrefs.load();
    expect(BeautyPrefs.enabled, isFalse);
    expect(BeautyPrefs.useInCalls, isTrue);
    expect(BeautyPrefs.settings.presetId, 'natural');
  });

  test('forCamera is disabled until the master switch is on', () async {
    await BeautyPrefs.load();
    expect(BeautyPrefs.forCamera().enabled, isFalse);
    BeautyPrefs.enabled = true;
    expect(BeautyPrefs.forCamera().enabled, isTrue);
  });

  test('forCall folds in BOTH switches', () async {
    await BeautyPrefs.load();
    BeautyPrefs.enabled = true;
    BeautyPrefs.useInCalls = false;
    // The way back from a stuttering call has to be one tap, without giving up
    // the feature on snaps.
    expect(BeautyPrefs.forCall().enabled, isFalse);
    expect(BeautyPrefs.forCamera().enabled, isTrue);
  });

  test('a saved look survives a reload', () async {
    await BeautyPrefs.load();
    BeautyPrefs.enabled = true;
    BeautyPrefs.settings = const BeautySettings(
      enabled: true,
      amount: 0.7,
      presetId: 'evening',
      retouch: RetouchParams(smooth: 0.6),
    );
    await BeautyPrefs.save();

    BeautyPrefs.debugReset();
    await BeautyPrefs.load();

    expect(BeautyPrefs.enabled, isTrue);
    expect(BeautyPrefs.settings.presetId, 'evening');
    expect(BeautyPrefs.settings.amount, 0.7);
    expect(BeautyPrefs.settings.retouch.smooth, 0.6);
  });

  test('a corrupt look document does not throw and defaults stand', () async {
    SharedPreferences.setMockInitialValues({
      BeautyPrefs.lookKey: '{not json at all',
      BeautyPrefs.enabledKey: true,
    });
    await BeautyPrefs.load();
    // A kill mid-save must cost the look, never the launch.
    expect(BeautyPrefs.enabled, isTrue);
    expect(BeautyPrefs.settings.presetId, 'natural');
  });

  test('a look naming a retired preset degrades to Custom', () async {
    SharedPreferences.setMockInitialValues({
      BeautyPrefs.lookKey: jsonEncode(const {
        'enabled': true,
        'amount': 0.4,
        'presetId': 'retired_look',
      }),
    });
    await BeautyPrefs.load();
    expect(BeautyPrefs.settings.presetId, isNull);
    expect(BeautyPrefs.settings.amount, 0.4);
  });

  test('load is idempotent — a second call does not re-read', () async {
    await BeautyPrefs.load();
    expect(BeautyPrefs.enabled, isFalse);
    // Change the store underneath. The guard must mean the in-memory value
    // wins, or a concurrent writer could yank settings out from under the UI.
    SharedPreferences.setMockInitialValues({BeautyPrefs.enabledKey: true});
    await BeautyPrefs.load();
    expect(BeautyPrefs.enabled, isFalse);
  });
}
