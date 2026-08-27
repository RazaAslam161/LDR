import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart';

/// The UI-sound kill switch has the OPPOSITE safe direction from ads and
/// cipher-only: those must fail OFF, sound must fail ON (following the local
/// toggle). Everything here pins that inversion, because a future reader who
/// pattern-matches on the other two flags will "fix" it the wrong way round.
void main() {
  void reset() {
    ReleaseGate.channel = 'sideload';
    ReleaseGate.uiSoundKilled = false;
    ReleaseGate.applyRow({
      'min_build': 1,
      'latest_build': ReleaseGate.buildNumber,
    });
  }

  group('ui sound kill switch', () {
    test('an absent column means NOT killed — sound stays with the user', () {
      reset();
      // The degrading column-set contract: every environment that has not run
      // the migration serves a row with no ui_sound_kill key at all, and that
      // absence must leave a shipped, working feature alone.
      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
      });
      expect(ReleaseGate.uiSoundKilled, isFalse);
    });

    test('only an explicit true kills', () {
      reset();
      for (final wrong in [false, null, 'true', 1, 0]) {
        ReleaseGate.applyRow({
          'min_build': 1,
          'latest_build': ReleaseGate.buildNumber,
          'ui_sound_kill': wrong,
        });
        expect(ReleaseGate.uiSoundKilled, isFalse,
            reason: '$wrong must not read as a kill');
      }
      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
        'ui_sound_kill': true,
      });
      expect(ReleaseGate.uiSoundKilled, isTrue);
    });

    test('flipping the kill bumps revision so a live Settings tile reacts', () {
      reset();
      final before = ReleaseGate.revision.value;
      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
        'ui_sound_kill': true,
      });
      expect(ReleaseGate.revision.value, before + 1);

      // And an unchanged kill does not wake listeners on every resume.
      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
        'ui_sound_kill': true,
      });
      expect(ReleaseGate.revision.value, before + 1);
    });

    test('the new column set is PREPENDED, never folded into an older one', () {
      // A new column appended to an existing generation 400s the whole select
      // on every environment that has not migrated, taking min_build_play and
      // chat_cipher_only down with it on every launch. This pin makes the
      // "own generation, newest first" law fail loudly instead of silently.
      // (The generation below withSoundKill was withAds when this flag was
      // born; ads were cancelled and their generation removed, so the pin
      // names the head and the shape, not a specific neighbour.)
      final source = File('lib/core/app/release_gate.dart').readAsStringSync();
      expect(source, contains('const columnSets = [withSoundKill, '),
          reason: 'withSoundKill must be its own generation at the head of '
              'columnSets');
      final cipherBody = RegExp(
        r"const withCipher = '([^;]+)';",
        dotAll: true,
      ).firstMatch(source)![1]!;
      expect(cipherBody, isNot(contains('ui_sound_kill')),
          reason: 'the older generation must stay exactly as shipped clients '
              'know it');
    });
  });
}
