import 'dart:ui';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/cover_entry_store.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The store decides which door a cover has. A wrong answer here is either a
/// public door coming back or the owner's move going dead, and both are
/// silent on the phone — so the modes are pinned against the backing maps.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The map handed to setMockInitialValues IS the backing store, mutated in
  // place, so holding the reference lets each test read the writes back.
  late Map<String, String> secure;

  setUp(() {
    secure = {};
    FlutterSecureStorage.setMockInitialValues(secure);
    SharedPreferences.setMockInitialValues({});
    CoverEntryStore.resetForTest();
  });

  TouchTrigger move(DisguiseCover cover) => TouchTrigger(
        cover: cover,
        box: const Size(411, 869),
        steps: const [TouchStep(x: 0.5, y: 0.5, holdMs: 3000)],
        radius: const [0.1],
        windowMs: 4000,
        gapMs: 1000,
      );

  test('nothing recorded is none', () async {
    final (mode, trigger) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.none);
    expect(trigger, isNull);
  });

  test('save writes the record and the mirror; resolve finds custom',
      () async {
    expect(await CoverEntryStore.save(move(DisguiseCover.notes)), isTrue);
    expect(secure[CoverEntryStore.keyFor(DisguiseCover.notes)], isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(CoverEntryStore.mirrorKeyFor(DisguiseCover.notes)),
        isTrue,);

    CoverEntryStore.resetForTest();
    final (mode, trigger) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.custom);
    expect(trigger, isA<TouchTrigger>());
  });

  test("records are per cover: another cover's move is not this one's",
      () async {
    await CoverEntryStore.save(move(DisguiseCover.notes));
    final (mode, _) = await CoverEntryStore.resolve(DisguiseCover.calculator);
    expect(mode, CoverEntryMode.none);
  });

  test('a mirror with an unreadable record is customUnknown', () async {
    await CoverEntryStore.save(move(DisguiseCover.notes));
    secure[CoverEntryStore.keyFor(DisguiseCover.notes)] = '{"v":99}';
    CoverEntryStore.resetForTest();
    final (mode, trigger) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.customUnknown,
        reason: 'the public door must not come back because the keystore '
            'lost its mind',);
    expect(trigger, isNull);
  });

  test('a mirror with no record at all is customUnknown', () async {
    SharedPreferences.setMockInitialValues({
      CoverEntryStore.mirrorKeyFor(DisguiseCover.notes): true,
    });
    final (mode, _) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.customUnknown);
  });

  test('a record whose mirror write was lost still counts as the move',
      () async {
    secure[CoverEntryStore.keyFor(DisguiseCover.notes)] =
        move(DisguiseCover.notes).encode();
    final (mode, trigger) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.custom);
    expect(trigger, isNotNull);
  });

  test('a record that names another cover is refused', () async {
    secure[CoverEntryStore.keyFor(DisguiseCover.notes)] =
        move(DisguiseCover.calculator).encode();
    final (mode, _) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.none);
  });

  test('clear removes both halves', () async {
    await CoverEntryStore.save(move(DisguiseCover.notes));
    await CoverEntryStore.clear(DisguiseCover.notes);
    expect(secure[CoverEntryStore.keyFor(DisguiseCover.notes)], isNull);
    final (mode, _) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.none);
  });

  test('the decoded record is cached for the process', () async {
    await CoverEntryStore.save(move(DisguiseCover.notes));
    secure.clear();
    final (mode, _) = await CoverEntryStore.resolve(DisguiseCover.notes);
    expect(mode, CoverEntryMode.custom,
        reason: 'a host rebuilt on every cover raise must not pay the '
            'keystore each time',);
  });
}
