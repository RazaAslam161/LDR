import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

// LOCATION SERVICE ARCHITECTURE
// ─────────────────────────────────────────────────────────────────────────────
// Primary:   LocationForegroundService — persistent Android foreground service,
//            streams GPS continuously, survives backgrounding + screen-off.
// Fallback:  BgLocationService (WorkManager) — ~15min safety net for edge
//            cases where the foreground service is killed by extreme OEM
//            battery managers (OnePlus/Vivo/Xiaomi aggressive modes).
// The foreground service is started/stopped by LocationService.
// WorkManager remains registered as insurance only.
//
// OEM battery optimisation — MANUAL STEP required on both devices:
//   OnePlus: Settings → Battery → Battery Optimization → All Apps →
//            System Services → Don't Optimize
//   Vivo:    Settings → Battery → High Background Power Consumption →
//            System Services → Allow
// Without this, aggressive OEM battery managers may still kill the
// foreground service after ~20 minutes of screen-off.

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
      // LOCATION ONLY — must never call setOnline or any app-activity method.
      // GPS runs while the user may be asleep. setLiveLocation never stamps
      // app_last_active_at, so GPS can't pollute online / last-seen.
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

// ─── Primary: persistent foreground location service ───────────────────────

@pragma('vm:entry-point')
void locationForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_LocationTaskHandler());
}

class _LocationTaskHandler extends TaskHandler {
  StreamSubscription<Position>? _positionSub;
  String? _coupleId;
  String? _uid;
  double? _lastLabelLat;
  double? _lastLabelLon;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      // Re-init dependencies the isolate can't inherit from the main isolate.
      WidgetsFlutterBinding.ensureInitialized();
      await dotenv.load();
      await SupabaseService.init();

      final prefs = await SharedPreferences.getInstance();
      _coupleId = prefs.getString('fg_location_couple_id');
      _uid = prefs.getString('fg_location_uid');
      if (_coupleId == null || _uid == null) return;

      // Start the continuous GPS stream — survives backgrounding + screen-off.
      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10, // metres — same cadence as the foreground stream
        ),
      ).listen((position) => _onPosition(position));
    } catch (_) {
      // Never throw from a foreground handler — would crash the service.
    }
  }

  Future<void> _onPosition(Position position) async {
    try {
      // Respect the user's current sharing mode — only push while 'precise'.
      final prefs = await SharedPreferences.getInstance();
      final mode = prefs.getString('location_sharing_mode_$_uid');
      if (mode != 'precise') return;

      // Reverse-geocode a label only when meaningfully moved (>700m), matching
      // LocationService._labelIfMoved behaviour.
      String? label;
      final moved = _lastLabelLat == null ||
          Geolocator.distanceBetween(_lastLabelLat!, _lastLabelLon!,
                  position.latitude, position.longitude) >
              700;
      if (moved) {
        try {
          final placemarks = await placemarkFromCoordinates(
              position.latitude, position.longitude);
          if (placemarks.isNotEmpty) {
            final p = placemarks.first;
            label = [p.locality, p.country]
                .where((s) => s != null && s.isNotEmpty)
                .join(', ');
          }
        } catch (_) {}
        _lastLabelLat = position.latitude;
        _lastLabelLon = position.longitude;
      }

      await PresenceService.setLiveLocation(
        _coupleId!,
        lat: position.latitude,
        lon: position.longitude,
        accuracy: position.accuracy,
        label: label,
      );
    } catch (_) {}
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // GPS stream drives updates — no periodic action needed here.
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _positionSub?.cancel();
  }
}

class LocationForegroundService {
  LocationForegroundService._();

  static Future<void> _ensureInit() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'tethered_location',
        channelName: 'Live Location',
        channelDescription: 'Sharing your live location with your partner',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        // Silent — no sound, no vibration. Status indicator, not an alert.
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Starts the persistent foreground location service. The GPS stream runs
  /// inside it; survives app backgrounding, screen-off, and (with the OEM
  /// battery note above) most aggressive OEM managers.
  static Future<void> start({
    required String coupleId,
    required String uid,
  }) async {
    try {
      await _ensureInit();
      // Store ids for the isolate to read on cold-start.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fg_location_couple_id', coupleId);
      await prefs.setString('fg_location_uid', uid);

      await FlutterForegroundTask.startService(
        serviceId: 640,
        serviceTypes: const [ForegroundServiceTypes.location],
        notificationTitle: 'Tethered · Live Location',
        notificationText: 'Sharing your location with your partner',
        callback: locationForegroundCallback,
      );
    } catch (_) {
      // Silent fallback to in-app stream + WorkManager. Never crash on it.
    }
  }

  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }

  static Future<bool> get isRunning async =>
      FlutterForegroundTask.isRunningService;
}
