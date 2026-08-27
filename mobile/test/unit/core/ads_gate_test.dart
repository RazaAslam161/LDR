import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/ads/ads_service.dart';
import 'package:miles/core/app/release_gate.dart';

/// The ads switch has exactly one job: never serve unless a server row said so.
///
/// Every branch below is a way the flag could arrive wrong — the column missing
/// because an environment never ran the migration, the value arriving as the
/// string 'true' from a hand-written row, a live unit id that was never pasted
/// in. Each has to land on "no ads", because unlike the chat cipher flag there
/// is no later fix that un-serves an impression: the enforcement lands on a
/// publisher account shared with AdSense.
void main() {
  void reset() {
    ReleaseGate.channel = 'sideload';
    ReleaseGate.applyRow({
      'min_build': 1,
      'latest_build': ReleaseGate.buildNumber,
    });
  }

  group('ads_enabled parsing', () {
    test('absent column leaves ads off', () {
      reset();
      // Exactly the shape the fallback select returns on an environment that
      // has not run the migration — the key is not present at all.
      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
      });

      expect(ReleaseGate.adsEnabled, isFalse);
    });

    test('a string, a 1, or a null is not a yes', () {
      reset();
      for (final value in <Object?>['true', 1, null, 'yes']) {
        ReleaseGate.applyRow({
          'min_build': 1,
          'latest_build': ReleaseGate.buildNumber,
          'ads_enabled': value,
        });

        expect(ReleaseGate.adsEnabled, isFalse, reason: 'accepted $value');
      }
    });

    test('a real true turns it on and announces the change once', () {
      reset();
      final before = ReleaseGate.revision.value;

      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
        'ads_enabled': true,
      });

      expect(ReleaseGate.adsEnabled, isTrue);
      // The bump is what lets a running app lose its banner on a resume rather
      // than only on a cold start — the whole point of a switch you can flip.
      expect(ReleaseGate.revision.value, before + 1);
    });

    test('flipping back off is also a change worth announcing', () {
      reset();
      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
        'ads_enabled': true,
      });
      final before = ReleaseGate.revision.value;

      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
        'ads_enabled': false,
      });

      expect(ReleaseGate.adsEnabled, isFalse);
      expect(ReleaseGate.revision.value, before + 1);
    });
  });

  group('AdsService.available', () {
    tearDown(reset);

    test('is false while the server says no, whatever else is set', () {
      reset();

      expect(ReleaseGate.adsEnabled, isFalse);
      expect(AdsService.available, isFalse);
    });

    test('needs BOTH the server flag and a unit id', () {
      reset();
      ReleaseGate.applyRow({
        'min_build': 1,
        'latest_build': ReleaseGate.buildNumber,
        'ads_enabled': true,
      });

      // Asserts the CONJUNCTION, not today's placeholder value. An earlier
      // version of this test asserted liveBannerUnitId was empty, which would
      // have gone red on the day the owner correctly pasted a real one — a
      // suite that punishes the change it is waiting for.
      expect(
        AdsService.available,
        ReleaseGate.adsEnabled && AdsService.bannerUnitId.isNotEmpty,
      );
    });

    test('a debug build never points at the live unit', () {
      expect(AdsService.bannerUnitId, AdsService.sampleBannerUnitId);
    });

    test('the App ID is a tilde id and the unit is a slash id', () {
      // They differ by one character and get swapped; a swapped App ID is a
      // startup crash rather than a missed fill.
      expect(AdsService.sampleAppId, contains('~'));
      expect(AdsService.sampleAppId, isNot(contains('/')));
      expect(AdsService.sampleBannerUnitId, contains('/'));
      expect(AdsService.sampleBannerUnitId, isNot(contains('~')));
    });
  });
}
