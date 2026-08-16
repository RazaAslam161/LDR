import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/location_service.dart';

/// Answers whatever the test sets, and records whether the OS sheet was raised.
class _FakeGeolocator extends GeolocatorPlatform {
  _FakeGeolocator(this.permission, {this.serviceEnabled = true});

  LocationPermission permission;
  final bool serviceEnabled;
  int requests = 0;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return permission = LocationPermission.whileInUse;
  }

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;
}

/// Sharing "on" while the handset says no.
///
/// Every one of these used to be the same thing to the code — a bare
/// `return null` — so the app that believed it was sharing a location, the one
/// whose permission had been revoked, and the one whose owner had never been
/// asked all looked identical from the inside. Each is repaired somewhere
/// different, so the point of these tests is that they stay distinguishable.
void main() {
  _grantedModeTests();

  test('permission held and location on is the only unblocked state', () async {
    GeolocatorPlatform.instance = _FakeGeolocator(LocationPermission.whileInUse);
    expect(await LocationService.check(), LocationBlock.none);
  });

  test('location switched off device-wide is not a permission problem',
      () async {
    // The case that was silent: permission granted, GPS off. The app happily
    // reported nothing wrong and sent nothing for as long as the toggle stayed
    // off, and only the system location page can undo it.
    GeolocatorPlatform.instance =
        _FakeGeolocator(LocationPermission.always, serviceEnabled: false);
    expect(await LocationService.check(), LocationBlock.serviceDisabled);
  });

  test('a refusal that can be re-asked is separate from one that cannot',
      () async {
    GeolocatorPlatform.instance = _FakeGeolocator(LocationPermission.denied);
    expect(await LocationService.check(), LocationBlock.denied);

    GeolocatorPlatform.instance =
        _FakeGeolocator(LocationPermission.deniedForever);
    expect(await LocationService.check(), LocationBlock.deniedForever);
  });

  test('an undeterminable permission counts as re-askable, not permanent',
      () async {
    // The web fallback. Treating it as deniedForever would send the user to a
    // settings page that has nothing on it to change.
    GeolocatorPlatform.instance =
        _FakeGeolocator(LocationPermission.unableToDetermine);
    expect(await LocationService.check(), LocationBlock.denied);
  });

  test('check() never raises the system sheet', () async {
    // It runs on every 15s tick and on every Settings open.
    final fake = _FakeGeolocator(LocationPermission.denied);
    GeolocatorPlatform.instance = fake;
    await LocationService.check();
    expect(fake.requests, 0);
  });

  test('request() asks when asking is still possible', () async {
    final fake = _FakeGeolocator(LocationPermission.denied);
    GeolocatorPlatform.instance = fake;
    expect(await LocationService.request(), LocationBlock.none);
    expect(fake.requests, 1);
  });

  test('request() does not ask once the answer is permanent', () async {
    // Android silently drops the second sheet; calling it anyway produces a
    // button that visibly does nothing, which is what sent users looking for a
    // toggle that was never the problem.
    final fake = _FakeGeolocator(LocationPermission.deniedForever);
    GeolocatorPlatform.instance = fake;
    expect(await LocationService.request(), LocationBlock.deniedForever);
    expect(fake.requests, 0);
  });

  test('a blocked permission outranks a switched-off service', () async {
    // Both are wrong at once on a fresh install with GPS off. They lead to two
    // different system pages, and the permission is the one the app can do
    // something about, so it has to be the one reported.
    GeolocatorPlatform.instance = _FakeGeolocator(
        LocationPermission.deniedForever,
        serviceEnabled: false,);
    expect(await LocationService.check(), LocationBlock.deniedForever);
  });
}

/// First-run default. Granting location and then seeing only a city name reads
/// as the feature being broken — city mode stores no coordinates, so there is
/// nothing for the partner's map to draw. But Android 12+ lets the user
/// downgrade the grant to approximate in the same dialog, and claiming
/// 'precise' there would render a kilometres-wide fix as an exact pin.
void _grantedModeTests() {
  // Mirrors LocationService.grantedMode: the only input is what the platform
  // says it granted.
  String modeFor(String? platformAccuracy) => switch (platformAccuracy) {
        'reduced' => 'city',
        'precise' => 'precise',
        _ => 'precise', // platforms with no such concept
      };

  group('first-run sharing mode follows the actual grant', () {
    test('a precise grant shares precise, with no trip to Settings', () {
      expect(modeFor('precise'), 'precise');
    });

    test('an approximate grant is stored as city, not as a fake precise', () {
      expect(modeFor('reduced'), 'city');
    });

    test('a platform without the toggle is treated as precise', () {
      expect(modeFor(null), 'precise');
    });

    test("the default is never 'off' — that was the old two-switch bug", () {
      for (final a in ['precise', 'reduced', null]) {
        expect(modeFor(a), isNot('off'));
      }
    });
  });
}
