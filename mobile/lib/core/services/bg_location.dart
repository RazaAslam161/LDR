import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:workmanager/workmanager.dart';

const _taskName = 'bgLocationUpdate';
const _uniqueName = 'tethered-bg-location';

/// Periodic background location updates WITHOUT a persistent notification, via
/// WorkManager. Cadence is ~15 min (Android's minimum for periodic work).
///
/// Best-effort by design: aggressive OEM battery managers (OnePlus, Vivo,
/// Xiaomi…) may delay or skip runs. For more reliable updates the user must
/// exempt the app from battery optimisation. Only updates while the sharing
/// mode is 'precise'.
@pragma('vm:entry-point')
void bgLocationCallback() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await dotenv.load();
      await SupabaseService.init();
      final uid = SupabaseService.currentUserId;
      if (uid == null) return true;

      final profile = await SupabaseRepository.fetchMyProfile();
      final coupleId = profile?.coupleId;
      if (coupleId == null) return true;

      // Respect the user's current choice — only share while 'precise' is on.
      final mine = await PresenceService.fetchMine(coupleId);
      if (mine?.locationSharingMode != 'precise') return true;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await PresenceService.setLiveLocation(
        coupleId,
        lat: pos.latitude,
        lon: pos.longitude,
        accuracy: pos.accuracy,
      );
      return true;
    } catch (_) {
      // Never throw — that would trigger WorkManager retry/backoff churn.
      return true;
    }
  });
}

class BgLocationService {
  BgLocationService._();
  static bool _inited = false;

  static Future<void> _ensureInit() async {
    if (_inited) return;
    _inited = true;
    await Workmanager().initialize(bgLocationCallback);
  }

  /// Start ~15-min background location updates (no notification).
  static Future<void> enable() async {
    try {
      await _ensureInit();
      await Workmanager().registerPeriodicTask(
        _uniqueName,
        _taskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {}
  }

  static Future<void> disable() async {
    try {
      await _ensureInit();
      await Workmanager().cancelByUniqueName(_uniqueName);
    } catch (_) {}
  }
}
