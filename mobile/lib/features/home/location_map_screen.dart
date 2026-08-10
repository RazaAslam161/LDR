// TETHERED REALTIME CONTRACT
// ─────────────────────────────────────────────────────────────────────────────
// This screen consumes partnerPresenceProvider (Pattern A). It does NOT
// subscribe its own presence channel — the provider handles all realtime
// location updates and follows the realtimeResumed re-subscribe pattern.
//
// All timestamps parsed as .toUtc(). Freshness window: 45s.
// Stale data shown in grey — never with a live green pulse.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:url_launcher/url_launcher.dart';

class LocationMapScreen extends ConsumerStatefulWidget {
  const LocationMapScreen({
    required this.coupleId, required this.partnerName, super.key,
  });

  final String coupleId;
  final String partnerName;

  @override
  ConsumerState<LocationMapScreen> createState() => _LocationMapScreenState();
}

class _LocationMapScreenState extends ConsumerState<LocationMapScreen>
    with TickerProviderStateMixin {
  final _map = MapController();

  late final AnimationController _pulse;
  late final AnimationController _move;
  late final AnimationController _distancePulse;
  LatLng? _animFrom;
  LatLng? _animTo;

  // My coords — read once on init; for v1 we use the latest cached presence
  // of the current user (no separate stream here — the home screen already
  // owns my-location streaming).
  double? _myLat;
  double? _myLon;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _distancePulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _move = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..addListener(_onMoveTick);

    // Refresh my position every 15s so the "YOU" pin + distance readout stay
    // live while the map is open. Cheap (uses last-known, no GPS warm-up).
    _myPosPoll = Timer.periodic(const Duration(seconds: 15), (_) {
      _loadMyCoords();
    });
  }

  Timer? _myPosPoll;

  void _onMoveTick() {
    final from = _animFrom;
    final to = _animTo;
    if (from == null || to == null) return;
    final t = Curves.easeInOut.transform(_move.value);
    try {
      _map.move(
        LatLng(
          from.latitude + (to.latitude - from.latitude) * t,
          from.longitude + (to.longitude - from.longitude) * t,
        ),
        _map.camera.zoom,
      );
    } catch (_) {}
  }

  void _glideTo(LatLng target) {
    try {
      _animFrom = _map.camera.center;
    } catch (_) {
      _animFrom = target;
    }
    _animTo = target;
    _move.forward(from: 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadMyCoords();
  }

  /// Fetches MY own location (not the partner's). Uses last-known position so
  /// the pin shows up instantly without a permission prompt or GPS wait. If
  /// last-known is null, falls back to a live high-accuracy read.
  Future<void> _loadMyCoords() async {
    if (_myLat != null && _myLon != null) return; // already seeded
    try {
      var pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted) return;
      setState(() {
        _myLat = pos!.latitude;
        _myLon = pos.longitude;
      });
    } catch (_) {
      // Permission denied or location off — leave _myLat/_myLon null.
      // Map will still show the partner pin if they're sharing.
    }
  }

  void _fitBoth(LatLng? partner, LatLng? me) {
    try {
      if (partner != null && me != null) {
        _map.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints([partner, me]),
            padding: const EdgeInsets.all(80),
          ),
        );
      } else if (partner != null) {
        _map.move(partner, 15);
      } else if (me != null) {
        _map.move(me, 15);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _myPosPoll?.cancel();
    _pulse.dispose();
    _move.dispose();
    _distancePulse.dispose();
    super.dispose();
  }

  String _distanceText(LatLng? p, LatLng? me) {
    if (p == null || me == null) return '—';
    final m = const Distance().as(LengthUnit.Meter, me, p);
    if (m < 1000) return '${m.round()} m apart';
    return '${(m / 1000).toStringAsFixed(1)} km apart';
  }

  @override
  Widget build(BuildContext context) {
    final presence = ref.watch(partnerPresenceProvider);
    final partner = presence?.isSharingLive ?? false ? presence : null;
    final partnerPoint = partner?.latitude != null && partner?.longitude != null
        ? LatLng(partner!.latitude!, partner.longitude!)
        : null;
    final myPoint = (_myLat != null && _myLon != null)
        ? LatLng(_myLat!, _myLon!)
        : null;

    // Animate the partner pin smoothly when it moves — never snap.
    if (partnerPoint != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _glideTo(partnerPoint);
      });
    }

    return Scaffold(
      backgroundColor: MilesColors.night,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── Layer 1: full-screen FlutterMap ────────────────────────────
          Positioned.fill(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: partnerPoint ?? myPoint ?? const LatLng(0, 0),
                initialZoom: partnerPoint != null ? 15 : 3,
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.miles.miles',
                  maxZoom: 19,
                ),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution(
                      '© OpenStreetMap contributors',
                      onTap: () => launchUrl(Uri.parse(
                          'https://www.openstreetmap.org/copyright',),),
                    ),
                  ],
                ),
                if (partnerPoint != null && myPoint != null)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: [myPoint, partnerPoint],
                        color: MilesColors.blush.withValues(alpha: 0.55),
                        strokeWidth: 1.5,
                        pattern: const StrokePattern.dotted(),
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (partnerPoint != null)
                      Marker(
                        point: partnerPoint,
                        width: 60,
                        height: 60,
                        alignment: Alignment.center,
                        child: _PartnerMarker(
                          pulse: _pulse,
                          name: widget.partnerName,
                          updatedAt: partner?.locationUpdatedAt,
                        ),
                      ),
                    if (myPoint != null)
                      Marker(
                        point: myPoint,
                        width: 32,
                        height: 32,
                        child: const _MyPinMarker(),
                      ),
                  ],
                ),
              ],
            ),
          ),

          // ── Layer 2: top chrome ──────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    _ChromeButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    Column(
                      children: [
                        _ChromeButton(
                          icon: Icons.my_location_rounded,
                          iconColor: MilesColors.ember,
                          onTap: () => _fitBoth(partnerPoint, myPoint),
                        ),
                        const SizedBox(height: 8),
                        _ChromeButton(
                          icon: Icons.explore_rounded,
                          onTap: () {
                            try {
                              _map.rotate(0);
                            } catch (_) {}
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Layer 3: partner info pill ───────────────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 72,
            right: 72,
            child: _PartnerInfoPill(
              name: widget.partnerName,
              label: partner?.locationLabel,
              updatedAt: partner?.locationUpdatedAt,
              isSharing: partner != null,
            ),
          ),

          // ── Layer 4: distance chip ───────────────────────────────────────
          if (partnerPoint != null && myPoint != null)
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).size.height * 0.62,
              child: Center(
                child: _DistanceChip(
                  pulse: _distancePulse,
                  text: _distanceText(partnerPoint, myPoint),
                ),
              ),
            ),

          // ── Layer 5: bottom panel ────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),),
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  20,
                  16,
                  20,
                  MediaQuery.of(context).padding.bottom + 16,
                ),
                decoration: const BoxDecoration(
                  color: MilesColors.surface1,
                  border: Border(
                    top: BorderSide(
                        color: MilesColors.gilt, width: 0.8,),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: '🧭',
                            label: 'Navigate',
                            enabled: partnerPoint != null,
                            onTap: () async {
                              final uri = Uri.parse(
                                  'google.navigation:q=${partnerPoint!.latitude},${partnerPoint.longitude}',);
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri);
                              } else {
                                await launchUrl(Uri.parse(
                                    'https://maps.google.com/?q=${partnerPoint.latitude},${partnerPoint.longitude}',),);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ActionButton(
                            icon: '⏱',
                            label: 'Send ETA',
                            enabled: partnerPoint != null && myPoint != null,
                            onTap: () async {
                              final dist =
                                  _distanceText(partnerPoint, myPoint);
                              await ChatRepository.sendText(
                                widget.coupleId,
                                "I'm $dist away, heading your way 💕",
                              );
                              // context.mounted, not mounted: this closure runs
                              // under a Builder, so `mounted` answers for the
                              // State while `context` belongs to a different
                              // element that may already be gone.
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Sent your ETA 💌'),
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    if (partner == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Ask ${widget.partnerName} to share location',
                          style: const TextStyle(
                            color: MilesColors.faint,
                            fontSize: 12,
                            fontFamily: 'Inter',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Private widgets ─────────────────────────────────────────────────────

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.icon,
    required this.onTap,
    this.iconColor = MilesColors.cream50,
  });
  final IconData icon;
  final VoidCallback onTap;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: Material(
        color: MilesColors.surface1,
        shape: const CircleBorder(
          side: BorderSide(color: MilesColors.gilt, width: 0.8),
        ),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, color: iconColor, size: 18),
          ),
        ),
      ),
    );
  }
}

class _PartnerInfoPill extends StatelessWidget {
  const _PartnerInfoPill({
    required this.name,
    required this.label,
    required this.updatedAt,
    required this.isSharing,
  });

  final String name;
  final String? label;
  final DateTime? updatedAt;
  final bool isSharing;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MilesColors.gilt, width: 0.8),
        ),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: MilesColors.cream50,
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    fontFamily: 'Fraunces',
                  ),
                ),
                Text(
                  isSharing
                      ? (label ?? 'Live location')
                      : "$name isn't sharing right now",
                  style: const TextStyle(
                    color: MilesColors.taupe,
                    fontSize: 11,
                    fontFamily: 'Inter',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            const Spacer(),
            _FreshnessChip(updatedAt: updatedAt),
          ],
        ),
      ),
    );
  }
}

/// Sage "LIVE" pill when fresh (<45s), warm yellow "Xm ago" when recent (<5min),
/// grey when stale. Never shows a live pulse on data older than 45s.
class _FreshnessChip extends StatefulWidget {
  const _FreshnessChip({required this.updatedAt});
  final DateTime? updatedAt;

  @override
  State<_FreshnessChip> createState() => _FreshnessChipState();
}

class _FreshnessChipState extends State<_FreshnessChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dot;

  @override
  void initState() {
    super.initState();
    _dot = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _dot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final at = widget.updatedAt;
    if (at == null) return const SizedBox.shrink();
    final secs = DateTime.now().toUtc().difference(at.toUtc()).inSeconds;
    String label;
    Color color;
    if (secs < 45) {
      label = '● LIVE';
      color = MilesColors.sage;
    } else if (secs < 300) {
      label = '${secs ~/ 60}m ago';
      color = MilesColors.star;
    } else {
      label = '${secs ~/ 60}m ago';
      color = MilesColors.faint;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          fontFamily: 'Inter',
        ),
      ),
    );
  }
}

class _DistanceChip extends StatelessWidget {
  const _DistanceChip({required this.pulse, required this.text});
  final Animation<double> pulse;
  final String text;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: MilesColors.gilt, width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: pulse,
              builder: (_, __) {
                final opacity = 0.6 + 0.4 * pulse.value;
                return Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: MilesColors.ember.withValues(alpha: opacity),
                    shape: BoxShape.circle,
                  ),
                );
              },
            ),
            const SizedBox(width: 6),
            Text(
              text,
              style: const TextStyle(
                color: MilesColors.cream50,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                fontFamily: 'Inter',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });
  final String icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: MilesColors.surface1,
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: MilesColors.gilt, width: 0.8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(icon, style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 12,
                      fontFamily: 'Inter',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Partner pin with pulsing radar halo + LIVE badge.
/// Halo only shown when locationUpdatedAt < 45s (freshness check).
class _PartnerMarker extends StatelessWidget {
  const _PartnerMarker({
    required this.pulse,
    required this.name,
    required this.updatedAt,
  });
  final Animation<double> pulse;
  final String name;
  final DateTime? updatedAt;

  @override
  Widget build(BuildContext context) {
    final fresh = updatedAt != null &&
        DateTime.now().toUtc().difference(updatedAt!.toUtc()).inSeconds < 45;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        // Radar halo — only when fresh
        if (fresh)
          AnimatedBuilder(
            animation: pulse,
            builder: (_, __) {
              final scale = 1.0 + 0.6 * pulse.value;
              final opacity = 0.8 * (1 - pulse.value);
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: MilesColors.blush.withValues(alpha: opacity),
                        width: 2,),
                  ),
                ),
              );
            },
          ),
        // Avatar circle
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [MilesColors.emberSoft, MilesColors.ember],
            ),
            border: Border.all(color: MilesColors.ember, width: 2),
            boxShadow: [
              BoxShadow(
                  color: MilesColors.ember.withValues(alpha: 0.5),
                  blurRadius: 10,),
            ],
          ),
          child: Center(
            child: Text(
              initial,
              style: const TextStyle(
                color: MilesColors.cream50,
                fontSize: 16,
                fontFamily: 'Fraunces',
              ),
            ),
          ),
        ),
        // LIVE badge below
        Positioned(
          bottom: -10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              fresh ? 'LIVE' : _ago(updatedAt),
              style: TextStyle(
                color: fresh ? MilesColors.sage : MilesColors.faint,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                fontFamily: 'Inter',
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _ago(DateTime? at) {
    if (at == null) return '';
    final mins =
        DateTime.now().toUtc().difference(at.toUtc()).inMinutes;
    if (mins < 1) return 'now';
    return '${mins}m ago';
  }
}

/// "YOU" pin — sage circle with label below.
class _MyPinMarker extends StatelessWidget {
  const _MyPinMarker();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: MilesColors.sage.withValues(alpha: 0.9),
            border: Border.all(color: MilesColors.cream50, width: 2),
          ),
        ),
        const Positioned(
          bottom: -12,
          child: Text(
            'YOU',
            style: TextStyle(
              color: MilesColors.cream50,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              fontFamily: 'Inter',
            ),
          ),
        ),
      ],
    );
  }
}
