import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:miles/core/ads/ads_service.dart';
import 'package:miles/core/ads/anchored_banner.dart';
import 'package:miles/core/app/release_gate.dart';

/// The band's contract is about SPACE, not about ads.
///
/// It sits directly above the Touch tab's instruction text, which sits above
/// the type chips, which sit above two photographs people tap. If the band's
/// height moves when an ad arrives, everything below it moves with it — and
/// the finger that was already travelling lands somewhere else. So the height
/// is asserted here in both the loaded and the never-loads case, and the
/// never-loads case is the ordinary one: a new AdMob app is on limited serving
/// until its readiness review clears.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void setAds({required bool on}) {
    ReleaseGate.channel = 'sideload';
    ReleaseGate.applyRow({
      'min_build': 1,
      'latest_build': ReleaseGate.buildNumber,
      'ads_enabled': on,
    });
  }

  var consentLookups = 0;

  /// Swapped at the plugin's own seam rather than at the wire.
  ///
  /// Mocking the method channel does not work here and fails in a way worth
  /// recording: the UMP channel is built with a private codec the package does
  /// not export, so a StandardMethodCodec mock cannot even decode the outgoing
  /// call and the send throws "Message corrupted" before any handler runs.
  /// [ConsentInformation.instance] is a settable static for exactly this.
  ///
  /// Consent is refused, which is what makes the rest of the SDK unreachable:
  /// AdsService stops at canRequestAds() and never calls MobileAds or
  /// ConsentForm, so no channel is touched at all. That is also the state under
  /// test — the band holding its space while no ad arrives.
  setUp(() {
    consentLookups = 0;
    AnchoredBannerBand.resetRequestThrottle();
    ConsentInformation.instance = _RefusingConsent(() => consentLookups++);
  });

  tearDown(() => setAds(on: false));

  Future<void> pump(WidgetTester tester, {required bool suppressed}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AnchoredBannerBand(suppressed: suppressed),
              const Text('instructions'),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('reserves its full height before any ad exists', (tester) async {
    setAds(on: true);

    await pump(tester, suppressed: false);

    expect(find.byType(AdWidget), findsNothing);
    expect(
      tester.getSize(find.byType(AnchoredBannerBand)).height,
      AnchoredBannerBand.adHeight + AnchoredBannerBand.gap + 1,
    );
  });

  testWidgets('suppressed keeps the space and shows no creative',
      (tester) async {
    setAds(on: true);

    await pump(tester, suppressed: true);

    expect(find.byType(AdWidget), findsNothing);
    expect(
      tester.getSize(find.byType(AnchoredBannerBand)).height,
      AnchoredBannerBand.adHeight + AnchoredBannerBand.gap + 1,
    );
  });

  testWidgets('toggling suppression does not move the screen', (tester) async {
    setAds(on: true);
    await pump(tester, suppressed: false);
    final before = tester.getTopLeft(find.text('instructions'));

    await pump(tester, suppressed: true);
    await tester.pump();

    expect(tester.getTopLeft(find.text('instructions')), before);
  });

  testWidgets('takes no space at all while the server says no', (tester) async {
    setAds(on: false);

    await pump(tester, suppressed: false);

    expect(tester.getSize(find.byType(AnchoredBannerBand)).height, 0);
  });

  testWidgets('the switch works in BOTH directions without a restart',
      (tester) async {
    // The regression this exists for: AdsService memoised its readiness with
    // `??=`, so the first call — which happens with ads OFF, the shipping
    // state, and which merely opening Settings reaches — cached a completed
    // Future(false) for the life of the process. Flipping the server row to
    // true then reserved 63dp and requested nothing, forever. On a phone
    // Android keeps alive for days, "restart the process" is not a remedy.
    setAds(on: false);
    await pump(tester, suppressed: false);
    expect(tester.getSize(find.byType(AnchoredBannerBand)).height, 0);

    // The move that used to poison the cache — and the assertion that it no
    // longer can. `available` is now read OUTSIDE the memo, so a call made
    // while the server says no returns without ever reaching the consent
    // layer, and therefore leaves nothing behind to remember.
    expect(await AdsService.ensureReady(), isFalse);
    expect(
      consentLookups,
      0,
      reason: 'a call made with ads off consulted the SDK and cached the answer',
    );

    setAds(on: true);
    await tester.pump();

    expect(
      tester.getSize(find.byType(AnchoredBannerBand)).height,
      AnchoredBannerBand.adHeight + AnchoredBannerBand.gap + 1,
      reason: 'the band did not react to the server turning ads on',
    );
    // The consent layer refuses in this suite, so no ad can arrive — but the
    // question is whether the SDK was ASKED at all after the flip. Under the
    // old `??=` this was 0: the band reserved its 63dp and requested nothing.
    expect(
      consentLookups,
      1,
      reason: 'turning ads on did not trigger a request',
    );
  });

  testWidgets('the gap below the creative is not zero', (tester) async {
    // The separation is the placement policy. A later edit that "tidies" it to
    // zero puts an ad flush against the type chips.
    expect(AnchoredBannerBand.gap, greaterThanOrEqualTo(8.0));
  });
}

/// A consent layer that always answers "not allowed to ask for ads".
///
/// Only the two methods AdsService reaches are implemented; the rest throw so a
/// future change that starts calling one fails loudly here instead of silently
/// returning a default that means "consented".
class _RefusingConsent implements ConsentInformation {
  _RefusingConsent(this.onLookup);

  final void Function() onLookup;

  @override
  void requestConsentInfoUpdate(
    ConsentRequestParameters params,
    OnConsentInfoUpdateSuccessListener onSuccess,
    OnConsentInfoUpdateFailureListener onFailure,
  ) {
    onLookup();
    onFailure(FormError(errorCode: 0, message: 'no consent in tests'));
  }

  @override
  Future<bool> canRequestAds() async => false;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName} is not stubbed');
}
