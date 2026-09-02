import 'dart:collection';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/features/disguise/entry/cover_entry_store.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Applying a cover writes the move before the alias switch, because the
/// switch is where Android may force-stop the process. What must hold on every
/// path: a successful switch leaves the move readable; a failed one leaves the
/// worn cover's move untouched and the target's gone; nothing else changes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('miles/disguise');

  void mockChannel(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  late Map<String, String> secure;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = {};
    FlutterSecureStorage.setMockInitialValues(secure);
    CoverEntryStore.resetForTest();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  TouchTrigger move(DisguiseCover cover) => TouchTrigger(
        cover: cover,
        box: const Size(411, 869),
        steps: const [TouchStep(x: 0.5, y: 0.5, holdMs: 3000)],
        radius: const [0.1],
        windowMs: 4000,
        gapMs: 1000,
      );

  final calculator =
      kDisguises.firstWhere((d) => d.cover == DisguiseCover.calculator);

  test('a confirmed switch leaves the move readable for the new cover',
      () async {
    mockChannel((c) async => c.method == 'setAlias' ? true : null);
    expect(
      await DisguiseService.apply(calculator,
          entry: move(DisguiseCover.calculator),),
      isTrue,
    );
    final (mode, _) = await CoverEntryStore.resolve(DisguiseCover.calculator);
    expect(mode, CoverEntryMode.custom);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('disguise_alias_id'), 'Calculator');
  });

  test('a refused switch keeps both moves — the target may already be worn',
      () async {
    // Worn: Notes, with a move.
    await CoverEntryStore.save(move(DisguiseCover.notes));
    SharedPreferences.setMockInitialValues({
      'disguise_alias_id': 'Notes',
      CoverEntryStore.mirrorKeyFor(DisguiseCover.notes): true,
    });
    mockChannel((c) async => c.method == 'setAlias'
        ? throw PlatformException(code: 'switch_failed')
        : null,);

    expect(
      await DisguiseService.apply(calculator,
          entry: move(DisguiseCover.calculator),),
      isFalse,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('disguise_alias_id'), 'Notes',
        reason: 'the identity rolls back',);
    final (calc, _) = await CoverEntryStore.resolve(DisguiseCover.calculator);
    expect(calc, CoverEntryMode.custom,
        reason: 'MainActivity enables the target BEFORE disabling the rest, '
            'so a throw in that loop leaves the new alias live — deleting '
            'its move would leave the worn cover with only the public hold',);
    final (worn, _) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(worn, CoverEntryMode.custom,
        reason: "the worn cover's move is not the one being replaced",);
  });

  test('a re-record of the cover already worn keeps its new move when the '
      'switch fails', () async {
    // The old record is already overwritten by the time the switch runs, and
    // the cover on the launcher is still this one: deleting the new move
    // here would leave the worn cover with no door but the public hold.
    await CoverEntryStore.save(move(DisguiseCover.calculator));
    SharedPreferences.setMockInitialValues({
      'disguise_alias_id': 'Calculator',
      CoverEntryStore.mirrorKeyFor(DisguiseCover.calculator): true,
    });
    mockChannel((c) async => c.method == 'setAlias'
        ? throw PlatformException(code: 'switch_failed')
        : null,);
    expect(
      await DisguiseService.apply(calculator,
          entry: move(DisguiseCover.calculator),),
      isFalse,
    );
    final (mode, _) = await CoverEntryStore.resolve(DisguiseCover.calculator);
    expect(mode, CoverEntryMode.custom);
  });

  test('a move that cannot be written stops the switch before it starts',
      () async {
    var switched = false;
    mockChannel((c) async {
      if (c.method == 'setAlias') switched = true;
      return true;
    });
    // A record for the wrong cover is the one thing save() refuses via the
    // assert; a keystore that throws is the field failure. Simulate the
    // latter by making the platform reject writes.
    FlutterSecureStorage.setMockInitialValues(_ThrowingMap());
    expect(
      await DisguiseService.apply(calculator,
          entry: move(DisguiseCover.calculator),),
      isFalse,
    );
    expect(switched, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('disguise_alias_id'), isNull);
  });

  test('applying the plain identity records nothing and clears nothing',
      () async {
    await CoverEntryStore.save(move(DisguiseCover.notes));
    mockChannel((c) async => c.method == 'setAlias' ? true : null);
    expect(await DisguiseService.apply(kPlainProfile), isTrue);
    final (mode, _) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.custom,
        reason: 'taking a cover off keeps its move for the day it goes back on',);
  });
}

/// A backing map whose writes fail, standing in for a keystore that throws.
class _ThrowingMap extends MapBase<String, String> {
  final Map<String, String> _inner = {};

  @override
  String? operator [](Object? key) => _inner[key];

  @override
  void operator []=(String key, String value) =>
      throw PlatformException(code: 'keystore');

  @override
  void clear() => _inner.clear();

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  String? remove(Object? key) => _inner.remove(key);
}
