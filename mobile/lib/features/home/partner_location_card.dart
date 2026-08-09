import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/home/map_3d_screen.dart';
import 'package:url_launcher/url_launcher.dart';

/// Live partner location on the dashboard. Shows an OpenStreetMap (no API key)
/// with the partner's marker that animates to each new fix, "updated Xs ago",
/// and the distance between you. When the partner stops sharing it shows a
/// "paused" state — never a stale pin presented as live.
class PartnerLocationCard extends StatefulWidget {
  const PartnerLocationCard({
    super.key,
    required this.partner,
    required this.partnerName,
    required this.coupleId,
    this.myLat,
    this.myLon,
  });

  final Presence? partner;
  final String partnerName;
  final String coupleId;
  final double? myLat;
  final double? myLon;

  @override
  State<PartnerLocationCard> createState() => _PartnerLocationCardState();
}

class _PartnerLocationCardState extends State<PartnerLocationCard>
    with TickerProviderStateMixin {
  final _map = MapController();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();
  // Glides the camera smoothly between live fixes so movement is visible.
  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..addListener(_onMoveTick);
  LatLng? _animFrom;
  LatLng? _animTo;

  void _onMoveTick() {
    final from = _animFrom, to = _animTo;
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
  void dispose() {
    _pulse.dispose();
    _move.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PartnerLocationCard old) {
    super.didUpdateWidget(old);
    final p = widget.partner;
    if (p != null &&
        p.isSharingLive &&
        p.latitude != null &&
        p.longitude != null) {
      final moved = old.partner?.latitude != p.latitude ||
          old.partner?.longitude != p.longitude;
      if (moved) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _glideTo(LatLng(p.latitude!, p.longitude!));
        });
      }
    }
  }

  void _recenter() {
    final p = widget.partner;
    if (p == null || !p.isSharingLive) return;
    try {
      _map.move(LatLng(p.latitude!, p.longitude!), 16);
    } catch (_) {}
  }

  /// Opens the full-screen Google photorealistic 3D map at the partner's spot.
  void _open3D(LatLng point) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Map3DScreen(
        lat: point.latitude,
        lon: point.longitude,
        name: widget.partnerName,
      ),
    ));
  }

  String _agoText(DateTime? at) {
    if (at == null) return 'live';
    final secs = DateTime.now().difference(at).inSeconds;
    if (secs < 15) return 'just now';
    if (secs < 60) return '${secs}s ago';
    final mins = secs ~/ 60;
    if (mins < 60) return '${mins}m ago';
    return '${mins ~/ 60}h ago';
  }

  String? _distanceText() {
    final p = widget.partner;
    if (p == null || !p.isSharingLive) return null;
    if (widget.myLat == null || widget.myLon == null) return null;
    if (p.latitude == null || p.longitude == null) return null;
    final m = const Distance().as(
      LengthUnit.Meter,
      LatLng(widget.myLat!, widget.myLon!),
      LatLng(p.latitude!, p.longitude!),
    );
    if (m < 950) return '${m.round()} m apart';
    final km = m / 1000;
    return '${NumberFormat.decimalPattern().format(km.round())} km apart';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.partner;
    if (p == null || !p.isSharingLive) {
      return SurfacePanel(
        child: Row(
          children: [
            const Icon(Icons.location_off_outlined,
                color: MilesColors.taupe, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "${widget.partnerName} isn't sharing location right now",
                style: const TextStyle(color: MilesColors.taupe, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    final point = LatLng(p.latitude!, p.longitude!);
    final myPoint = (widget.myLat != null && widget.myLon != null)
        ? LatLng(widget.myLat!, widget.myLon!)
        : null;
    final dist = _distanceText();

    return SurfacePanel(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.place, color: MilesColors.blush, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.partnerName} · ${_agoText(p.locationUpdatedAt)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: MilesColors.cream50, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.threed_rotation,
                        color: MilesColors.gilt, size: 20),
                    onPressed: () => _open3D(point),
                    tooltip: 'View in 3D',
                  ),
                  IconButton(
                    icon: const Icon(Icons.my_location,
                        color: MilesColors.gilt, size: 20),
                    onPressed: _recenter,
                    tooltip: 'Recenter',
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 210,
              child: GestureDetector(
                onTap: () => context.push('/app/location-map', extra: {
                  'coupleId': widget.coupleId,
                  'partnerName': widget.partnerName,
                }),
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _map,
                      options: MapOptions(
                        initialCenter: point,
                        initialZoom: 15.5,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.pinchZoom |
                              InteractiveFlag.drag,
                        ),
                      ),
                      children: [
                        // CARTO Voyager — full OSM data with street names, POI
                        // labels, building outlines, parks, transit. Free, no
                        // API key, reliable CDN. (Standard raster tiles; the
                        // "no labels" issue with OSM's free server was caused
                        // by rate-limiting returning blank tiles.)
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
                                  'https://www.openstreetmap.org/copyright')),
                            ),
                          ],
                        ),
                          if (myPoint != null)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: [myPoint, point],
                                  color: MilesColors.blush
                                      .withValues(alpha: 0.55),
                                  strokeWidth: 1.5,
                                  pattern: StrokePattern.dotted(),
                                ),
                              ],
                            ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: point,
                              width: 48,
                              height: 54,
                              alignment: Alignment.bottomCenter,
                              child: _CuteMarker(
                                  pulse: _pulse, name: widget.partnerName),
                            ),
                            if (myPoint != null)
                              Marker(
                                point: myPoint,
                                width: 26,
                                height: 26,
                                child: const _MyDot(),
                              ),
                          ],
                        ),
                      ],
                    ),
                    // Tap affordance — "Full screen" pill, bottom-right.
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          color: Colors.black.withValues(alpha: 0.45),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.fullscreen_rounded,
                                  color: MilesColors.cream50, size: 14),
                              const SizedBox(width: 4),
                              const Text(
                                'Full screen',
                                style: TextStyle(
                                  color: MilesColors.cream50,
                                  fontSize: 11,
                                  fontFamily: 'Inter',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (dist != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                child: Row(
                  children: [
                    const Icon(Icons.favorite,
                        color: MilesColors.blush, size: 14),
                    const SizedBox(width: 8),
                    Text(dist,
                        style: const TextStyle(
                            color: MilesColors.cream50, fontSize: 13)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small, cute partner marker: a gently-bobbing avatar with a soft "live"
/// halo and a little ground shadow, anchored at the location point.
class _CuteMarker extends StatelessWidget {
  const _CuteMarker({required this.pulse, required this.name});
  final Animation<double> pulse;
  final String name;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) {
        final v = pulse.value; // 0..1 looping
        final bob = math.sin(v * 2 * math.pi) * 2.5; // gentle up/down
        final halo = 1 - (v - 0.5).abs() * 2; // 0 → 1 → 0
        return Stack(
          alignment: Alignment.bottomCenter,
          clipBehavior: Clip.none,
          children: [
            // ground shadow
            Container(
              width: 12,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            // avatar + halo, lifted off the ground and gently bobbing
            Positioned(
              bottom: 6,
              child: Transform.translate(
                offset: Offset(0, bob),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 24 + halo * 12,
                      height: 24 + halo * 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: MilesColors.blush.withValues(alpha: halo * 0.3),
                      ),
                    ),
                    Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: MilesColors.blush,
                        border:
                            Border.all(color: MilesColors.cream50, width: 2),
                        boxShadow: [
                          BoxShadow(
                              color: MilesColors.blush.withValues(alpha: 0.6),
                              blurRadius: 8),
                        ],
                      ),
                      child: Center(
                        child: Text(initial,
                            style: const TextStyle(
                                color: MilesColors.cream50,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "You are here" dot.
class _MyDot extends StatelessWidget {
  const _MyDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: MilesColors.sage,
        border: Border.all(color: MilesColors.cream50, width: 2),
        boxShadow: [
          BoxShadow(
              color: MilesColors.sage.withValues(alpha: 0.5), blurRadius: 8),
        ],
      ),
    );
  }
}
