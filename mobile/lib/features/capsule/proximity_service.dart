import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Snapshot of the proximity check, pushed to the UI.
class ProximityStatus {
  const ProximityStatus({
    this.permission,
    this.serviceEnabled = true,
    this.haveMyLocation = false,
    this.partnerSeen = false,
    this.distanceMeters,
    this.withinRange = false,
    this.error,
  });

  final LocationPermission? permission;
  final bool serviceEnabled;
  final bool haveMyLocation;
  final bool partnerSeen;
  final double? distanceMeters;
  final bool withinRange;
  final String? error;

  bool get permissionBlocked =>
      permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever ||
      !serviceEnabled;
}

/// Privacy-preserving "are we together?" check.
///
/// We NEVER persist coordinates server-side. Each partner fetches their own
/// COARSE location and broadcasts it over an EPHEMERAL Supabase Realtime
/// broadcast channel (transient pub/sub, not stored in any table). Each device
/// computes the Haversine distance locally; coordinates live only in memory on
/// the two phones, only while both have this screen open at the reunion.
class ProximityService {
  ProximityService({this.thresholdMeters = 100});

  final double thresholdMeters;

  RealtimeChannel? _channel;
  Timer? _timer;
  Position? _mine;
  String? _uid;
  void Function(ProximityStatus)? _onUpdate;
  double? _lastDistance;

  Future<LocationPermission> ensurePermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm;
  }

  Future<void> start({
    required String coupleId,
    required void Function(ProximityStatus) onUpdate,
  }) async {
    _onUpdate = onUpdate;
    _uid = SupabaseService.currentUserId;

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final perm = await ensurePermission();
    if (!serviceEnabled ||
        perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      onUpdate(ProximityStatus(permission: perm, serviceEnabled: serviceEnabled));
      return;
    }

    _channel = SupabaseService.client.channel('capsule_proximity:$coupleId', opts: RealtimeChannelConfig(private: true));
    _channel!
        .onBroadcast(
          event: 'loc',
          callback: (payload) {
            final data = payload['payload'] is Map
                ? Map<String, dynamic>.from(payload['payload'] as Map)
                : payload;
            if (data['uid'] == _uid) return; // ignore my own echo
            final mine = _mine;
            if (mine == null || data['lat'] == null) return;
            final d = haversine(
              mine.latitude,
              mine.longitude,
              (data['lat'] as num).toDouble(),
              (data['lon'] as num).toDouble(),
            );
            _lastDistance = d;
            onUpdate(ProximityStatus(
              permission: perm,
              haveMyLocation: true,
              partnerSeen: true,
              distanceMeters: d,
              withinRange: d <= thresholdMeters,
            ),);
          },
        )
        .subscribe();

    await _ping();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _ping());
  }

  Future<void> _ping() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
      );
      _mine = pos;
      await _channel?.sendBroadcastMessage(
        event: 'loc',
        payload: {'uid': _uid, 'lat': pos.latitude, 'lon': pos.longitude},
      );
      // Surface "we have your location, waiting for them" until a partner ping
      // lands (don't clobber a known distance).
      _onUpdate?.call(ProximityStatus(
        haveMyLocation: true,
        partnerSeen: _lastDistance != null,
        distanceMeters: _lastDistance,
        withinRange: _lastDistance != null && _lastDistance! <= thresholdMeters,
      ),);
    } catch (e) {
      _onUpdate?.call(ProximityStatus(error: e.toString()));
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _channel?.unsubscribe();
    _channel = null;
  }

  static double haversine(double lat1, double lon1, double lat2, double lon2) {
    const earth = 6371000.0; // metres
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
    return earth * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  static double _rad(double deg) => deg * pi / 180.0;
}
