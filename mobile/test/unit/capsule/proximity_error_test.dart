import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/features/capsule/proximity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A handset with no location provider: the platform channel throws before the
/// check has even started.
class _ThrowingGeolocator extends GeolocatorPlatform {
  @override
  Future<bool> isLocationServiceEnabled() async =>
      throw Exception('no location provider on this device');
}

/// "Are we together?" that never answers.
///
/// The capsule screen leaves "Looking for your location…" only when a status
/// arrives, so a throw on the way in used to strand it there for good: it left
/// [ProximityService.start] as an unhandled async error, no status was ever
/// pushed, and the one thing on screen was a sentence about waiting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ErrorReporter.resetForTest();
  });

  test('a location check that throws on the way in answers with an error',
      () async {
    GeolocatorPlatform.instance = _ThrowingGeolocator();

    final seen = <ProximityStatus>[];
    await ProximityService().start(
      coupleId: 'c1',
      onUpdate: seen.add,
    );

    expect(seen, hasLength(1));
    expect(seen.single.error, isNotNull);
    // And distinct from "location is off": nothing in the system settings
    // repairs this, so the screen must not offer that button instead of retry.
    expect(seen.single.permissionBlocked, isFalse);
  });
}
