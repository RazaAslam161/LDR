import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The motion law, made mechanical — in the idiom of repo_hygiene_test.dart:
/// scan source, count what is tolerated, and make every exception a decision
/// someone has to move a number to take.
///
/// Scope: the Sensory Overhaul's motion set. Files outside it carry their own
/// history (glow_button.dart still animates a shadow — found, not fixed, and
/// its rewrite belongs to the rollout phase, not to this detector's scope).
void main() {
  const motionSet = [
    'lib/core/ui/motion.dart',
    'lib/core/ui/route_motion.dart',
    'lib/core/ui/tab_dissolve.dart',
    'lib/core/widgets/breathing_glow.dart',
    'lib/core/widgets/countdown_digits.dart',
    'lib/core/widgets/ember_background.dart',
    'lib/core/widgets/ember_press.dart',
    'lib/core/widgets/gilt_nav_icon.dart',
    'lib/core/widgets/gravity_float.dart',
    'lib/core/widgets/presence_character.dart',
    // Added 2026-09-01: it was constructing two controllers and never
    // consulting off(), so it animated for users who had asked their phone
    // to stop. Its durations are MilesMotion tokens now.
    'lib/core/widgets/presence_figure_overlay.dart',
    'lib/core/widgets/screen_entrance.dart',
    'lib/core/widgets/tilt_parallax.dart',
    'lib/core/widgets/wordmark.dart',
    'lib/features/breath/widgets/breath_orb.dart',
    'lib/features/reach/widgets/reach_pulse.dart',
    'lib/features/intro/intro_splash_screen.dart',
    // The Doorstep. The scene's DRAWING files are in the set; scene_state
    // (a pure mapper, no widgets) and scene_sync (a realtime subscription)
    // are not motion code and stay outside it.
    'lib/features/unlink/scene/unlink_end_overlay.dart',
    'lib/features/unlink/scene/doorstep_scene.dart',
  ];

  String read(String path) {
    final f = File(path);
    expect(f.existsSync(), isTrue,
        reason: '$path is named by the motion law but does not exist — '
            'update motionSet when a file moves',);
    return f.readAsStringSync();
  }

  /// Strip comments so prose about durations cannot trip the detectors.
  String code(String src) => src
      .replaceAll(RegExp(r'///.*'), '')
      .replaceAll(RegExp(r'(?<!:)//.*'), '');

  test('raw Duration( literals in motion code stay countable', () {
    // Tokens, not numbers: one duration copied everywhere is the anti-pattern
    // MilesMotion exists to end. A raw Duration( in the set is either a TIMER
    // (a clock's cadence is not motion) or a defect. Each tolerated one is
    // listed with its reason; growing a number here is a deliberate act.
    const tolerated = <String, (int, String)>{
      'lib/core/ui/motion.dart': (
        18,
        'the token definitions themselves, including the Doorstep scene set '
            '(slam, shake, birdFlight, spokenWord, letterSlide, boltSlide, '
            'floodOpen, sceneLoop, duskFall) added 2026-08-30',
      ),
      'lib/core/ui/route_motion.dart': (
        2,
        'the 300ms framework transition duration the getters replace with '
            'zero when animations are off',
      ),
      'lib/core/widgets/countdown_digits.dart': (
        2,
        'timer cadences (1s/1min) — the clock ticking, not motion',
      ),
      'lib/core/widgets/ember_background.dart': (
        1,
        'the 36s ambient loop, expressed from its own _loopSeconds constant',
      ),
      'lib/features/unlink/scene/doorstep_scene.dart': (
        1,
        'the 1s conversation clock — a timer cadence like countdown_digits, '
            'not motion; the talk itself is arithmetic on ServerClock',
      ),
    };
    for (final path in motionSet) {
      final hits = RegExp(r'Duration\(')
          .allMatches(code(read(path)))
          .length;
      final allowed = tolerated[path]?.$1 ?? 0;
      expect(hits, lessThanOrEqualTo(allowed),
          reason: '$path has $hits raw Duration( uses; $allowed are '
              'tolerated (${tolerated[path]?.$2 ?? 'none'}). New motion '
              'durations belong in MilesMotion.',);
    }
  });

  test('every controller in the motion set knows about off()', () {
    // A controller that never consults MilesMotion.off runs for users who
    // asked their phone to stop animating. Every file that constructs one
    // must reference off() somewhere — the widget tests pin WHAT the off
    // path renders; this pins that the path exists at all.
    for (final path in motionSet) {
      final src = code(read(path));
      if (!src.contains('AnimationController(')) continue;
      expect(src.contains('MilesMotion.off('), isTrue,
          reason: '$path constructs an AnimationController but never '
              'consults MilesMotion.off — animations-off users get a ticker '
              'they asked to be rid of',);
    }
  });

  test('no shadow blur in the motion set, animated or not', () {
    // The original BreathingGlow animated a BoxShadow's blur — the exact
    // per-frame raster cost motion.dart:12-15 bans. Its rewrite removed the
    // shadow entirely; nothing in the set may bring one back, because a
    // static shadow next to an AnimationController is one refactor away from
    // an animated one.
    for (final path in motionSet) {
      expect(code(read(path)).contains('blurRadius'), isFalse,
          reason: '$path names blurRadius — the motion set is shadow-free '
              'by design',);
    }
  });

  test('curves in the motion set are tokens', () {
    // Curves.easeOutQuart spelled raw beside a token that IS easeOutQuart is
    // how a retune forks the feel. Curves.* may appear only in motion.dart,
    // where the tokens are defined; everywhere else spells the token.
    const tolerated = <String, (int, String)>{
      'lib/core/ui/motion.dart': (99, 'the token definitions'),
    };
    for (final path in motionSet) {
      final hits = RegExp(r'Curves\.').allMatches(code(read(path))).length;
      final allowed = tolerated[path]?.$1 ?? 0;
      expect(hits, lessThanOrEqualTo(allowed),
          reason: '$path spells ${hits} raw Curves.* — reference MilesMotion '
              'tokens instead',);
    }
  });
}
