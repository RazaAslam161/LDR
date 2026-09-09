import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';

/// What the app wears on its FIRST frame, on a platform that cannot answer.
///
/// `miles/disguise` is MainActivity's channel. iOS has no host for it, so
/// `loadEnabled()`'s invoke throws MissingPluginException, its catch swallows
/// that, and — before this was fixed — both class defaults stood: `enabled`
/// true and `plainDefault` false. DisguiseCoverHost resolves
/// `plainDefault ? kPlainProfile : kDefaultDisguise`, and kDefaultDisguise is
/// `kDisguises.first`, which is News.
///
/// So iOS opened on the fake news reader, and the two-finger ten-second hold
/// was the only way into the app. That is the exact inverse of what ships on
/// Play — both manifests set PLAIN_DEFAULT true with every cover
/// `enabled="false"`, so the app installs as itself and a cover is something
/// the owner switches ON (BRAIN §32/§34).
///
/// Both directions are pinned, because getting this backwards is a shipping
/// incident either way: a store build opening on a fake news reader is the
/// Deceptive Behavior finding the plain default exists to avoid, and an iOS
/// build that stops offering covers at all silently drops a feature.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('miles/disguise');

  setUp(() {
    DisguiseService.enabled = true;
    DisguiseService.plainDefault = false;
    // No handler registered: an invoke on this channel throws
    // MissingPluginException, which is exactly what iOS does.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS opens as ITSELF, not wearing a cover', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await DisguiseService.loadEnabled();

    expect(DisguiseService.plainDefault, isTrue,
        reason: 'plainDefault false on iOS resolves kDefaultDisguise — News — '
            'as the first frame, with only the entry gesture as a way in',);
    // The host reads `plainDefault ? kPlainProfile : kDefaultDisguise`, and
    // `choices` leads with the same identity, so asserting the head of choices
    // pins the resolved profile without reaching into a private getter.
    expect(DisguiseService.choices.first, same(kPlainProfile),
        reason: 'the plain profile is the one carrying DisguiseCover.none, '
            'which is what makes the host open the gate instead of drawing a '
            'cover',);
    expect(kPlainProfile.cover, DisguiseCover.none,
        reason: 'if this ever gains a cover, the first frame on iOS silently '
            'becomes that cover',);
  });

  test('iOS still CARRIES the disguise — the covers are not dropped', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    await DisguiseService.loadEnabled();

    expect(DisguiseService.enabled, isTrue,
        reason: 'the cover screens, the picker, the entry gesture and the '
            'persisted choice are pure Flutter and all work on iOS. Only the '
            'LAUNCHER swap is missing, and enabled=false would remove the '
            'feature rather than the missing half of it',);
    expect(DisguiseService.choices.first, same(kPlainProfile),
        reason: 'plain identity FIRST, so switching away from it disables it',);
    expect(DisguiseService.choices.length, kDisguises.length + 1,
        reason: 'all nine covers stay on offer on iOS',);
  });

  test('a platform that CAN answer is still asked — Android is untouched',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var asked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      asked++;
      if (call.method == 'isEnabled') return true;
      if (call.method == 'isPlainDefault') return true;
      return null;
    });

    await DisguiseService.loadEnabled();

    expect(asked, 2,
        reason: 'the iOS short-circuit must not swallow the Android query — '
            'BuildConfig is the only thing that knows which flavor this is',);
  });

  test('Android with no host keeps the disguise, as it always did', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    await DisguiseService.loadEnabled();

    expect(DisguiseService.enabled, isTrue);
    expect(DisguiseService.plainDefault, isFalse,
        reason: 'a failed query on ANDROID must not strip the cover off a '
            'sideloaded phone mid-session — that fallback is deliberate and '
            'this fix must not have changed it',);
  });
}
