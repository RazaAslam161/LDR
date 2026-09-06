import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/features/chat/camera/beauty/beauty_prefs.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The remote kill for the retouch, pinned the way the sound kill is.
///
/// A native GL pipeline shipped to every install needs a way back that is one
/// UPDATE, not a release. These laws keep that switch wired end to end: the
/// column generation that reads it, the polarity that makes absence safe, and
/// the one place every consumer folds it in.
void main() {
  final source = File('lib/core/app/release_gate.dart').readAsStringSync();

  group('the column generation', () {
    test('beauty_kill is its own generation at the head of columnSets', () {
      // PostgREST 400s the WHOLE select when one column is missing. Folded
      // into an older generation, a fresh environment would lose min_build and
      // chat_cipher_only on every launch; as its own head it gives up only
      // itself.
      expect(source, contains('const columnSets = [withBeautyKill, withSoundKill, '));
      final body = RegExp("const withBeautyKill = '([^;]+)';", dotAll: true)
          .firstMatch(source)![1]!;
      expect(body, contains('beauty_kill'));
      expect(body, contains('ui_sound_kill'),
          reason: 'the head is the previous generation plus one column');
    });

    test('the migration is additive and re-runnable', () {
      final sql = File('../supabase/migrations/20260906120000_beauty_kill_switch.sql')
          .readAsStringSync();
      expect(sql, contains('add column if not exists beauty_kill'));
      expect(sql, contains('default false'));
      expect(sql.toLowerCase(), isNot(contains('drop column beauty_kill;\nalter')),
          reason: 'the rollback is documented, never executed by the forward file');
    });
  });

  group('polarity', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      BeautyPrefs.debugReset();
      ReleaseGate.beautyKilled = false;
    });
    tearDown(() {
      ReleaseGate.beautyKilled = false;
      BeautyPrefs.debugReset();
    });

    test('absent reads false and false means the local toggle rules', () {
      expect(source, contains("beautyKilled = row['beauty_kill'] == true;"),
          reason: 'anything but an explicit true must keep the feature on',);
      expect(ReleaseGate.beautyKilled, isFalse);
    });

    test('a kill switches every consumer off through forCamera', () async {
      await BeautyPrefs.load();
      BeautyPrefs.enabled = true;
      expect(BeautyPrefs.forCamera().enabled, isTrue);
      ReleaseGate.beautyKilled = true;
      expect(BeautyPrefs.forCamera().enabled, isFalse,
          reason: 'the camera must open without the effect',);
      expect(BeautyPrefs.forCall().enabled, isFalse,
          reason: 'forCall goes through forCamera, so the call is covered too',);
      // The kill does not rewrite the user's preference: lifting it restores.
      ReleaseGate.beautyKilled = false;
      expect(BeautyPrefs.enabled, isTrue);
      expect(BeautyPrefs.forCamera(), isA<BeautySettings>()
          .having((s) => s.enabled, 'enabled', isTrue),);
    });

    test('a change in the kill bumps the revision so Settings redraws', () {
      final parse = source.indexOf("beautyKilled = row['beauty_kill'] == true;");
      final bump = source.indexOf('beautyKilled != wasBeautyKilled', parse);
      expect(bump, greaterThan(parse),
          reason: 'the Retouch row listens to revision; without the bump it '
              'shows a switch the server has already turned off',);
    });
  });
}
