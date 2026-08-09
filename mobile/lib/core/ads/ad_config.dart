import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Central AdMob configuration for Miles.
///
/// The IDs below are currently Google's official **TEST** ad unit IDs. They
/// always return test ads and are safe to ship while developing — tapping them
/// earns nothing and never risks your AdMob account.
///
/// Before publishing to the Play Store:
///   1. Create an AdMob account → https://admob.google.com
///   2. Register the app, create ad units, and paste the real IDs into the
///      `_prod*` constants below.
///   3. Set [useTestAds] to `false`.
///   4. Replace the APPLICATION_ID meta-data in
///      android/app/src/main/AndroidManifest.xml with your real AdMob App ID.
///
/// NEVER click your own live ads — Google bans accounts for self-clicks.
class AdConfig {
  AdConfig._();

  /// While true, all units resolve to Google's test IDs.
  static const bool useTestAds = true;

  /// Master switch. A future "remove ads" paid upgrade flips this to false.
  ///
  /// OFF for the first public release. With [useTestAds] still true, every
  /// impression a real user generated would be a Google test ad: no revenue,
  /// and serving test ads in production is against AdMob policy. Leaving the
  /// SDK live also pulls the AD_ID permission, which has to be declared on
  /// the Play Data Safety form. Flip both back on together, once the real
  /// unit IDs below are filled in.
  static bool adsEnabled = false;

  // ── Google official TEST unit IDs ──────────────────────────────────
  static const String _testBannerAndroid =
      'ca-app-pub-3940256099942544/6300978111';
  static const String _testBannerIos =
      'ca-app-pub-3940256099942544/2934735716';
  static const String _testInterstitialAndroid =
      'ca-app-pub-3940256099942544/1033173712';
  static const String _testRewardedAndroid =
      'ca-app-pub-3940256099942544/5224354917';

  // ── Your real unit IDs (fill in before release, then set useTestAds=false)
  static const String _prodBannerAndroid = 'REPLACE_WITH_YOUR_BANNER_UNIT_ID';
  static const String _prodInterstitialAndroid =
      'REPLACE_WITH_YOUR_INTERSTITIAL_UNIT_ID';
  static const String _prodRewardedAndroid =
      'REPLACE_WITH_YOUR_REWARDED_UNIT_ID';

  static bool get _isIos => !kIsWeb && Platform.isIOS;

  static String get bannerUnitId {
    if (useTestAds) return _isIos ? _testBannerIos : _testBannerAndroid;
    return _prodBannerAndroid;
  }

  static String get interstitialUnitId =>
      useTestAds ? _testInterstitialAndroid : _prodInterstitialAndroid;

  static String get rewardedUnitId =>
      useTestAds ? _testRewardedAndroid : _prodRewardedAndroid;
}
