import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart' show ReleaseGate;

/// The human version has exactly one home.
///
/// The About card was rewritten to read [ReleaseGate.versionName] because a
/// hardcoded 'v0.1.0' in a footer was still saying 0.1.0 at build 30 — and the
/// literal came straight back in a second place (the Settings list row) on
/// 2026-08-29, where it read '0.1.0 (build)' beside a dialog one tap away
/// deriving the same value properly. Two version strings on one screen is the
/// exact confusion the rewrite ended.
///
/// The lockstep test next door pins pubspec's +N against
/// ReleaseGate.buildNumber; nothing pinned the x.y.z half, which the project's
/// own rules already call out as enforced nowhere. This is that half: a version
/// literal anywhere in lib/ except the constant itself is a copy waiting to
/// drift.
void main() {
  test('only release_gate.dart carries a version literal', () {
    final semver = RegExp(r"'\d+\.\d+\.\d+");
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.endsWith('lib/core/app/release_gate.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (semver.hasMatch(lines[i])) offenders.add('$path:${i + 1}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'a hardcoded version string outside ReleaseGate.versionName — '
            'render ReleaseGate.versionName instead: $offenders');
  });
}
