import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:miles/core/app/release_gate.dart';

/// AdMob wiring for the one banner slot this app has (the Touch tab).
///
/// AdMob, not AdSense. AdSense serves web inventory only and has no Android
/// SDK — the existing AdSense account is still the one that gets paid, because
/// signing up for AdMob with the same Google address links the two and AdMob
/// pays out through the AdSense payments profile. Nothing here talks to
/// AdSense directly, and nothing can.
///
/// Everything is OFF until a server row says otherwise. That is not caution
/// for its own sake: the screen this banner sits on renders a photograph the
/// couple chose, inside an encrypted bucket no part of this app can inspect,
/// and Google's publisher policy on sexual content is enforced against the
/// account rather than the screen. One publisher identity covers AdMob and
/// AdSense together, so a wrong call here reaches earnings that have nothing
/// to do with Miles. [ReleaseGate.adsEnabled] exists so that call can be
/// reversed with one UPDATE instead of a release.
class AdsService {
  AdsService._();

  /// Google's own sample IDs. They serve real test creatives against no
  /// account, which is what makes them the right PLACEHOLDER as well as the
  /// right debug value: a build carrying these can be run, screenshotted and
  /// tested without a publisher account existing yet, and it earns nothing and
  /// risks nothing if one of them ever escapes to a handset.
  ///
  /// The App ID (tilde) belongs in AndroidManifest.xml; the unit ID (slash)
  /// belongs here. They share a prefix and differ by one character, which is
  /// exactly why they get swapped — a swapped App ID crashes the app on the
  /// SDK's first call.
  static const sampleAppId = 'ca-app-pub-3940256099942544~3347511713';
  static const sampleBannerUnitId = 'ca-app-pub-3940256099942544/6300978111';

  /// The live banner unit, pasted from AdMob console > Ad units. Empty until
  /// the owner creates it, and empty is a hard stop rather than a fallback:
  /// silently serving test ads from a release build would read as "ads are
  /// working" while the account earned nothing.
  static const liveBannerUnitId = '';

  /// Which unit a request should use. Debug and profile builds never touch the
  /// live unit — impressions from a development handset are invalid traffic,
  /// and invalid traffic is assessed against the account, not the build.
  static String get bannerUnitId =>
      kReleaseMode ? liveBannerUnitId : sampleBannerUnitId;

  /// Whether a banner may be requested at all.
  ///
  /// The channel is deliberately NOT part of this. Miles is one app that ships
  /// on Play; the sideload flavour is a build mechanism, not a second product,
  /// and gating ads on it would be deciding the question twice. The single
  /// fleet-wide answer is the server row.
  static bool get available =>
      ReleaseGate.adsEnabled && bannerUnitId.isNotEmpty;

  /// In flight or SUCCEEDED. Never a remembered failure.
  ///
  /// `_x ??= attempt()` is the obvious spelling and it is wrong here, because a
  /// completed `Future(false)` is indistinguishable from a completed
  /// `Future(true)` to `??=`. The first call happens with the switch off — that
  /// is the shipping state, and merely opening Settings reaches it — so a
  /// cached "no" would outlive the server flipping to yes and make the kill
  /// switch OFF-only until the process died. On a phone Android keeps alive for
  /// days that is never, which is the whole reason this flag is a row.
  static Future<bool>? _consent;

  static const _consentTimeout = Duration(seconds: 15);

  /// Consent, then initialise, then answer whether a request may proceed.
  ///
  /// Lazy on purpose. Nothing in `main` calls this: the first mount of a banner
  /// does, which cannot happen behind the disguise cover, on the lock screen,
  /// or before sign-in — so a user who never opens Touch never loads the SDK,
  /// never fetches a consent form, and never pays the platform crossings on a
  /// cold start.
  static Future<bool> ensureReady() async {
    // Deliberately OUTSIDE the memo. This is the server's answer and it changes
    // under a running app.
    if (!available) return false;
    if (!await _ensureConsent()) return false;
    try {
      // canRequestAds() is the whole point of the consent step: outside the
      // EEA/UK/CH it is true immediately, and inside it reflects what the user
      // actually answered. Initialising anyway would request ads on a consent
      // state that does not allow them.
      if (!await ConsentInformation.instance.canRequestAds()) return false;
      await MobileAds.instance.initialize();
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(
          // G, not MA, and the app's own 18+ rating is not the reason to raise
          // it. The ad renders inches from a photograph of someone's partner;
          // a mature-rated creative in that spot is the app's fault however the
          // rating is set.
          maxAdContentRating: MaxAdContentRating.g,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('[ads] setup failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Runs the consent flow at most once per process, and only remembers it
  /// when it worked. A refused form can be answered later and a lookup that
  /// failed offline can succeed on the next visit; neither is a fact about the
  /// rest of the session.
  static Future<bool> _ensureConsent() {
    final pending = _consent;
    if (pending != null) return pending;
    final attempt = _gatherConsent();
    _consent = attempt;
    return attempt.then((ok) {
      if (!ok && identical(_consent, attempt)) _consent = null;
      return ok;
    });
  }

  static Future<bool> _gatherConsent() {
    final done = Completer<bool>();
    void finish({required bool ok}) {
      if (!done.isCompleted) done.complete(ok);
    }

    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () => ConsentForm.loadAndShowConsentFormIfRequired((error) {
        if (error != null) {
          debugPrint('[ads] consent form: ${error.errorCode} ${error.message}');
        }
        finish(ok: error == null);
      }),
      (error) {
        debugPrint('[ads] consent update: ${error.errorCode} ${error.message}');
        finish(ok: false);
      },
    );
    // Both callbacks come from the native side, and neither is guaranteed to
    // arrive — a form dismissed by a process death, or an SDK that never calls
    // back, would otherwise leave this Completer pending forever and every
    // later caller awaiting it. Timing out answers "no ads for now", which is
    // recoverable; hanging is not.
    return done.future.timeout(
      _consentTimeout,
      onTimeout: () {
        debugPrint('[ads] consent timed out after $_consentTimeout');
        return false;
      },
    );
  }

  /// Whether the user is entitled to reopen the consent form — true only where
  /// a privacy-options entry point is legally required (EEA/UK/CH). Settings
  /// asks this before drawing the row.
  ///
  /// Asks the CONSENT layer, not [ensureReady]. The obligation to offer this
  /// row is created by having gathered consent, and it does not go away because
  /// the user's answer means no ads can be requested — gating it on
  /// canRequestAds() would hide the control from part of the population it
  /// exists for.
  static Future<bool> privacyOptionsRequired() async {
    if (!available) return false;
    if (!await _ensureConsent()) return false;
    try {
      final status =
          await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
      return status == PrivacyOptionsRequirementStatus.required;
    } catch (e) {
      debugPrint('[ads] privacy options status: ${e.runtimeType}');
      return false;
    }
  }

  /// Reopens the consent form so a user can change their mind.
  static Future<void> showPrivacyOptions() async {
    try {
      await ConsentForm.showPrivacyOptionsForm((error) {
        if (error != null) {
          debugPrint('[ads] privacy form: ${error.errorCode} ${error.message}');
        }
      });
    } catch (e) {
      debugPrint('[ads] privacy form failed: ${e.runtimeType}');
    }
  }
}
