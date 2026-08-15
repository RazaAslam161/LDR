import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/services/update_service.dart';
import 'package:miles/features/disguise/disguise_service.dart';

/// UpdateService.available is the one gate that keeps self-update off the play
/// build and out of a client that has nothing to fetch. It reads three pieces of
/// global state; this pins every combination so a future edit cannot quietly let
/// the play channel download and install its own APK (a Play policy strike).
void main() {
  setUp(() {
    ReleaseGate.apkUrl = 'https://example.test/news.apk';
    ReleaseGate.latestBuild = ReleaseGate.buildNumber + 1;
    DisguiseService.enabled = true;
  });

  test('available when a newer build is published on the sideload channel', () {
    expect(UpdateService.available, isTrue);
  });

  test('never available on the play channel, even with a newer build', () {
    DisguiseService.enabled = false;
    expect(UpdateService.available, isFalse);
  });

  test('not available when no apk url is published', () {
    ReleaseGate.apkUrl = null;
    expect(UpdateService.available, isFalse);
    ReleaseGate.apkUrl = '';
    expect(UpdateService.available, isFalse);
  });

  test('not available when this build is already current', () {
    ReleaseGate.latestBuild = ReleaseGate.buildNumber;
    expect(UpdateService.available, isFalse);
  });

  test('not available when the server reports an older build than this one', () {
    ReleaseGate.latestBuild = ReleaseGate.buildNumber - 1;
    expect(UpdateService.available, isFalse);
  });
}
