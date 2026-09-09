import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/release_gate.dart';

/// Which FLEET an iOS install belongs to, and therefore which floor blocks it.
///
/// `miles/updater` is MainActivity's channel. iOS has no host for it, so the
/// query in _loadChannel() throws MissingPluginException — and before this was
/// fixed the catch left the safe ANDROID default standing: channel 'sideload',
/// channelKnown false.
///
/// Both halves of that are wrong on iOS, and the first is the dangerous one.
/// applyRow reads `channel == 'play' || channel == 'appstore' ? min_build_play
/// : min_build`, so a 'sideload' App Store install is held to the SIDELOAD
/// floor — the one raised to tell testers to install a hand-built APK over
/// themselves. Raising it would have blocked the entire iOS fleet with an
/// instruction no store install can act on.
///
/// The second is the dead end this gate's own doc comment warns about: the
/// block screen draws an exit only when channelKnown, so a blocked iOS user
/// would have seen the message, 'Check again', and nothing else.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const updater = MethodChannel('miles/updater');

  setUp(() {
    // Not just the channel: _channelKnown is process-wide and _loadChannel
    // early-returns on it, so without this the first test to resolve a channel
    // decides the answer for every test after it and they all pass vacuously.
    ReleaseGate.forgetChannelForTest();
    // No handler: an invoke throws MissingPluginException, which is exactly
    // what iOS does with a channel MainActivity owns.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(updater, null);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    ReleaseGate.channel = 'sideload';
  });

  test('iOS names itself appstore without asking a channel that is not there',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await ReleaseGate.loadChannelForTest();

    expect(ReleaseGate.channel, 'appstore');
    expect(ReleaseGate.channelKnown, isTrue,
        reason: 'false here is what makes the block screen a dead end: the '
            'store button is drawn only when the channel is KNOWN',);
  });

  test('an appstore install rides the store floor, never the sideload one', () {
    ReleaseGate.channel = 'appstore';

    // The shape that strands a fleet: the sideload floor raised past this
    // build to push testers onto a hand-installed APK, while the store floor
    // has deliberately not moved.
    ReleaseGate.applyRow({
      'min_build': ReleaseGate.buildNumber + 5,
      'min_build_play': 0,
      'latest_build': ReleaseGate.buildNumber,
    });

    expect(ReleaseGate.isBlocked, isFalse,
        reason: 'reading min_build on iOS blocks every App Store user the '
            'moment the sideload floor moves, and tells them to sideload an '
            'APK, which they cannot do',);
  });

  test('the store floor still blocks when it is the one that moved', () {
    ReleaseGate.channel = 'appstore';

    ReleaseGate.applyRow({
      'min_build': 1,
      'min_build_play': ReleaseGate.buildNumber + 1,
      'latest_build': ReleaseGate.buildNumber + 1,
    });

    expect(ReleaseGate.isBlocked, isTrue,
        reason: 'the point is the RIGHT floor, not no floor — an appstore '
            'install that can never be blocked is its own bug',);
  });

  test('android with no host still falls back to sideload, unchanged',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await ReleaseGate.loadChannelForTest();

    expect(ReleaseGate.channel, 'sideload',
        reason: 'ANY failure of the platform query must leave an Android '
            'client on the sideload floor — moving an unknown client onto the '
            'play floor unblocks phones min_build exists to block. The iOS '
            'short-circuit must not have weakened that.',);
    expect(ReleaseGate.channelKnown, isFalse);
  });
}
