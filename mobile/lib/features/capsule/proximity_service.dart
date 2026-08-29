import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
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

  /// A ceiling on one fix. Without it `getCurrentPosition` waits forever on a
  /// handset that never gets a lock — indoors, aeroplane mode, a GPS chip still
  /// warming — and the screen sat on "Looking for your location…" with no
  /// error, no timeout and nothing to press. A wait that cannot end is worse
  /// than a failure that can be retried.
  static const fixTimeout = Duration(seconds: 15);

  /// How long a fix stays true for. The partner distance used to be a bare
  /// `double?` set on the first broadcast and never cleared or aged: once
  /// `withinRange` latched, the card froze on "You're together 💞" and one
  /// metre count for the life of the screen — the partner could close their
  /// side and walk out, and nothing moved. Worse, it made the error card
  /// unreachable, because the screen tests `withinRange` before `error`.
  ///
  /// Longer than one 4s tick because a healthy partner's own fix may itself
  /// take up to [fixTimeout]: 20s is several missed broadcasts, not one slow
  /// one.
  static const fixTtl = Duration(seconds: 20);

  RealtimeChannel? _channel;
  Timer? _timer;
  String? _uid;
  void Function(ProximityStatus)? _onUpdate;

  /// Each fix carries the instant it was taken, in one value. Kept as a pair so
  /// a distance cannot outlive the two positions it was computed from — with
  /// the number in a field of its own there was simply nothing to age it by.
  ({Position pos, DateTime at})? _myFix;
  ({double meters, DateTime at})? _partnerFix;

  /// Set by [stop], never cleared: an instance is stopped once and thrown away.
  /// [start] awaits three platform calls before it arms anything, so a "Try
  /// again" that stops this instance mid-`start` would otherwise still go on to
  /// subscribe a channel and arm a 4s timer that no one holds a reference to —
  /// a second, invisible service broadcasting this phone's coordinates behind
  /// the live one.
  bool _stopped = false;

  /// One fix at a time. The timer fires every 4s but a fix may now wait up to
  /// [fixTimeout], so without this a slow handset stacks four concurrent
  /// location requests and broadcasts the same position four times.
  bool _pinging = false;

  /// What [start] found. Kept because a ping that throws must still answer
  /// "may this app use location, and is location on?" — the defaults say yes
  /// to both, and the UI hides its "Open location settings" button on that
  /// answer.
  LocationPermission? _permission;
  bool _serviceEnabled = true;

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

    final bool serviceEnabled;
    final LocationPermission perm;
    try {
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      perm = await ensurePermission();
    } catch (e, st) {
      // The platform channel throws here on handsets with no location provider
      // and when another screen already has a permission request in flight.
      // Unhandled, that threw out of start() into a caller that does not catch,
      // leaving the screen on "Looking for your location…" for good.
      ErrorReporter.report(e, st, kind: 'proximity');
      // Through [_onUpdate], never the captured `onUpdate`: [stop] nulls the
      // field, and that is the only thing standing between a stopped instance
      // and repainting the screen its replacement now owns.
      _onUpdate?.call(
        _snapshot(haveMyLocation: false, error: _errorMessage(e)),
      );
      return;
    }
    if (_stopped) return;
    _serviceEnabled = serviceEnabled;
    _permission = perm;
    if (!serviceEnabled ||
        perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      // Nothing this service can do repairs a system toggle, so no timer is
      // armed here and this instance will never speak again. Recovery is the
      // screen's job — it starts a FRESH service when the user comes back from
      // the settings app or presses "Check again" — which is why that card must
      // never be printed without those controls on it.
      _onUpdate?.call(_snapshot(haveMyLocation: false));
      return;
    }

    _uid = SupabaseService.currentUserId;
    _channel = SupabaseService.client.channel('capsule_proximity:$coupleId', opts: RealtimeChannelConfig(private: true));
    _channel!
        .onBroadcast(
          event: 'loc',
          callback: (payload) {
            final data = payload['payload'] is Map
                ? Map<String, dynamic>.from(payload['payload'] as Map)
                : payload;
            if (data['uid'] == _uid) return; // ignore my own echo
            // A distance is only as fresh as the OLDER of the two fixes it is
            // made of. [_freshMyFix] drops mine once it ages out, so a handset
            // whose own fixes have been failing for a minute stops minting new
            // distances against its last good position — which looked live on
            // the card while half its input was stale.
            final mine = _freshMyFix();
            if (mine == null || data['lat'] == null) return;
            final d = haversine(
              mine.pos.latitude,
              mine.pos.longitude,
              (data['lat'] as num).toDouble(),
              (data['lon'] as num).toDouble(),
            );
            _partnerFix = (meters: d, at: DateTime.now());
            // Through the same snapshot the ping path uses. Built raw, this
            // omitted serviceEnabled and took the constructor's `true`, so the
            // partner's next broadcast silently repainted "Location is off"
            // away — and with it the button that turns it back on — while this
            // phone's own location was still disabled.
            _onUpdate?.call(_snapshot(haveMyLocation: true));
          },
        )
        .subscribe();

    await _ping();
    if (_stopped) return;
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _ping());
  }

  Future<void> _ping() async {
    if (_pinging || _stopped) return;
    _pinging = true;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: fixTimeout,
        ),
      );
      _myFix = (pos: pos, at: DateTime.now());
      // A fix that lands proves location is back on and still permitted —
      // otherwise the flags set by the two exceptions below would latch for the
      // life of the screen and keep offering a settings button nobody needs.
      _serviceEnabled = true;
      if (_permission == LocationPermission.denied) {
        _permission = LocationPermission.whileInUse;
      }
      await _channel?.sendBroadcastMessage(
        event: 'loc',
        payload: {'uid': _uid, 'lat': pos.latitude, 'lon': pos.longitude},
      );
      // Surface "we have your location, waiting for them" until a partner ping
      // lands (don't clobber a known distance).
      _onUpdate?.call(_snapshot(haveMyLocation: true));
    } catch (e, st) {
      // This used to emit an ALL-DEFAULT status, which tore down state the
      // success path had deliberately kept: one throw on the 4s timer flipped
      // `withinRange` back to false, took the "Open the capsule" button away
      // from under the user's finger, and blamed the partner for a failure on
      // this handset. It also re-asserted `serviceEnabled: true`, hiding the
      // one actionable control — "Open location settings" — in the single case
      // that control fixes. The service still knew all of it; it just stopped
      // passing it on.
      if (e is LocationServiceDisabledException) _serviceEnabled = false;
      // Permission can be revoked from the shade mid-session. The grant cached
      // by start() would otherwise keep the UI on the generic error card
      // instead of the one control that repairs this — settings.
      if (e is PermissionDeniedException) _permission = LocationPermission.denied;
      ErrorReporter.report(e, st, kind: 'proximity');
      _onUpdate?.call(_snapshot(
        haveMyLocation: _freshMyFix() != null,
        error: _errorMessage(e),
      ),);
    } finally {
      _pinging = false;
    }
  }

  /// The screen prints this verbatim, so it is one short sentence a person can
  /// act on — the exception and its stack already went to [ErrorReporter], and
  /// `PlatformException(…, null, null)` on a capsule screen tells nobody
  /// anything. The type is kept because it is the only clue a field report has.
  static String _errorMessage(Object e) => e is TimeoutException
      ? 'Your phone could not get a location fix in ${fixTimeout.inSeconds}s.'
      : 'Your phone could not check its location (${e.runtimeType}).';

  /// Everything this service currently knows, so no caller has to guess at a
  /// default for the parts a single failed ping does not change. The 4s ping
  /// emits one of these on BOTH its paths, success and failure, so an expired
  /// partner fix is dropped on the next ping — it does not have to wait for a
  /// broadcast that, by definition, is not coming.
  ProximityStatus _snapshot({required bool haveMyLocation, String? error}) {
    final partner = _freshPartnerFix();
    return ProximityStatus(
      permission: _permission,
      serviceEnabled: _serviceEnabled,
      haveMyLocation: haveMyLocation,
      partnerSeen: partner != null,
      distanceMeters: partner?.meters,
      withinRange: partner != null && partner.meters <= thresholdMeters,
      error: error,
    );
  }

  /// Reads through the age check and DELETES what it finds expired, rather than
  /// filtering it at each read: a stale fix that still sits in the field is one
  /// a later caller can pick up without asking how old it is.
  ({double meters, DateTime at})? _freshPartnerFix() {
    final f = _partnerFix;
    if (f != null && DateTime.now().difference(f.at) > fixTtl) {
      _partnerFix = null;
    }
    return _partnerFix;
  }

  ({Position pos, DateTime at})? _freshMyFix() {
    final f = _myFix;
    if (f != null && DateTime.now().difference(f.at) > fixTtl) _myFix = null;
    return _myFix;
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    // A stopped service must never repaint the screen again. A fix already in
    // flight when "Try again" replaces this instance would otherwise land after
    // the new one has started and paint back the very failure being retried.
    _onUpdate = null;
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
