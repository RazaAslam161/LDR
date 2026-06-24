import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Initialises the Google Mobile Ads SDK exactly once at app startup.
///
/// Safe to call on any platform — it no-ops on web/desktop where the SDK is
/// unavailable, so the rest of the app never has to special-case it.
class AdService {
  AdService._();

  static bool _initialised = false;

  static Future<void> init() async {
    if (_initialised || kIsWeb) return;
    try {
      await MobileAds.instance.initialize();
      _initialised = true;
    } catch (_) {
      // Ads are non-critical: if init fails (e.g. no Play Services), the app
      // still runs fully — banners simply won't appear.
    }
  }
}
