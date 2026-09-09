import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Audio a PERSON made must play on the media stream, and in this app that
/// only happens through newContentPlayer().
///
/// Every other just_audio player inherits the app's one AudioSession, which
/// JustAudioEngine configures as sonification so a cue can duck rather than
/// seize focus; USAGE_ASSISTANCE_SONIFICATION lands on STREAM_SYSTEM, which
/// Android mutes in vibrate and silent and which the media rocker does not
/// move. A recording played through a bare AudioPlayer is therefore inaudible
/// on a phone in the state most phones are in.
///
/// The drift this pins has already happened once: the fix landed on the chat
/// bubble and left the capsule screen and the recorder cover on the silent
/// stream, with every gate green and the commit saying so in prose.
///
/// Source-level rather than behavioural, for the reason severance_teardown_test
/// gives — the attributes reach a real ExoPlayer, and nothing under
/// `flutter test` has one.
void main() {
  /// Whole-line comments stripped, so these checks match code rather than the
  /// prose that explains the rule — this very file names AudioPlayer( in a
  /// sentence, and the doc above newContentPlayer names it twice.
  String code(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  final construction = RegExp(r'\bAudioPlayer\s*\(');

  /// The gate counts, so it proves it can count before its zero means
  /// anything. Both halves matter: a matcher that misses a construction
  /// passes a file that is broken, and one that fires on a type annotation
  /// reds a file that is fine.
  test('the matcher fires on a construction and on nothing else', () {
    expect(construction.hasMatch('  final AudioPlayer _p = AudioPlayer();'),
        isTrue,);
    expect(
        construction
            .hasMatch('    _pool.add(AudioPlayer(handleAudioSessionActivation: false));'),
        isTrue,);
    expect(construction.hasMatch('  final _p = AudioPlayer (  );'), isTrue);
    expect(construction.hasMatch('  final AudioPlayer? _player;'), isFalse);
    expect(construction.hasMatch('  AudioPlayerPlatform platform;'), isFalse);
    expect(construction.hasMatch('  final _p = newContentPlayer();'), isFalse);
  });

  test('the comment stripper removes a line that only talks about one', () {
    expect(code('// builds an AudioPlayer() here\nfinal x = 1;'),
        isNot(contains('AudioPlayer(')),);
    expect(code('final p = AudioPlayer();'), contains('AudioPlayer('));
  });

  test('nothing outside the cue engine builds a bare AudioPlayer', () {
    // The engine's pool and bed ARE the sonification session — cues duck the
    // user's music on purpose — and the factory is where the media
    // attributes are set, so it is the one place that must construct one.
    const allowed = [
      'lib/core/services/sound/just_audio_engine.dart',
      'lib/core/services/sound/content_player.dart',
    ];
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final rel = f.path.replaceAll(r'\', '/');
      if (allowed.any(rel.endsWith)) continue;
      if (construction.hasMatch(code(f.readAsStringSync()))) offenders.add(rel);
    }
    expect(offenders, isEmpty,
        reason: 'these play into STREAM_SYSTEM — use newContentPlayer()',);
  });

  test('every surface that plays a recording takes the factory', () {
    // Named one by one rather than derived: the point is that all three are
    // still wired, so deleting a player is not a way to go green.
    const surfaces = [
      'lib/features/chat/widgets/voice_note_bubble.dart',
      'lib/features/capsule/capsule_detail_screen.dart',
      'lib/features/disguise/covers/recorder_cover.dart',
    ];
    for (final path in surfaces) {
      expect(code(File(path).readAsStringSync()), contains('newContentPlayer()'),
          reason: path,);
    }
  });
}
