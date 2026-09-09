import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/supabase_repository.dart';

/// Which transport a push token row claims.
///
/// `register_push_token` was called with `p_platform: 'android'` hardcoded, on
/// a column that has allowed both since the day it was written —
/// `check (platform in ('android','ios'))` and the p_platform argument both
/// landed in 20260906140300_a_push_token_belongs_to_a_device_not_an_account.sql.
/// It was built for two platforms and had only ever been sent one.
///
/// An APNs token filed as 'android' is a row the sender cannot route: nothing
/// else in it says which transport it belongs to, and FCM and APNs are not
/// interchangeable. The failure is silent at the client — the insert succeeds —
/// and shows up only as pushes that never arrive.
void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS files its token as ios', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(SupabaseRepository.pushPlatform, 'ios');
  });

  test('android is unchanged', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(SupabaseRepository.pushPlatform, 'android');
  });

  test('anything else falls to android, which is the shipped fleet', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(SupabaseRepository.pushPlatform, 'android',
        reason: 'the column only accepts android|ios, so an unexpected host '
            'must resolve to one of them or the insert is rejected outright',);
  });

  test('the value is one the CHECK constraint accepts', () {
    for (final p in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = p;
      expect(const {'android', 'ios'}, contains(SupabaseRepository.pushPlatform),
          reason: 'push_tokens.platform is check (platform in '
              "('android','ios')) — anything else fails the insert",);
    }
  });
}
