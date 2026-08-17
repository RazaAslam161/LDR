import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// pubspec's +N is what Gradle stamps into the artifact as versionCode;
/// ReleaseGate.buildNumber is what the running app tells the version gate it
/// is. Two constants in two files, and they drifted once — a versionCode-27
/// APK that reported itself as 26, which the gate can neither name nor block.
/// release.sh checks the pair on its own path only; this puts the check inside
/// `flutter test`, which every build path runs.
void main() {
  test('pubspec +N and ReleaseGate.buildNumber are the same number', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*[0-9.]+\+(\d+)\s*$', multiLine: true)
        .firstMatch(pubspec);
    expect(version, isNotNull,
        reason: 'pubspec.yaml has no "version: x.y.z+N" line');

    final gate = File('lib/core/app/release_gate.dart').readAsStringSync();
    final build = RegExp(r'buildNumber = (\d+);').firstMatch(gate);
    expect(build, isNotNull,
        reason: 'release_gate.dart has no "buildNumber = N;"');

    expect(build!.group(1), version!.group(1),
        reason: 'pubspec.yaml is +${version.group(1)} but '
            'ReleaseGate.buildNumber is ${build.group(1)} — bump both '
            'together (release.sh --bump edits the pair in one step).');
  });
}
