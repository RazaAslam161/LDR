import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:url_launcher/url_launcher.dart';

class LocationMapScreen extends ConsumerStatefulWidget {
  const LocationMapScreen({
    required this.coupleId,
    required this.partnerName,
    super.key,
  });

  final String coupleId;
  final String partnerName;

  @override
  ConsumerState<LocationMapScreen> createState() => _LocationMapScreenState();
}

class _LocationMapScreenState extends ConsumerState<LocationMapScreen>
    with TickerProviderStateMixin {
  GoogleMapController? _map;

  late final AnimationController _distancePulse;

  double? _myLat;
  double? _myLon;
  Timer? _myPosPoll;

  BitmapDescriptor? _partnerIconLive;
  BitmapDescriptor? _partnerIconStale;
  BitmapDescriptor? _myIcon;

  @override
  void initState() {
    super.initState();
    _distancePulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _myPosPoll = Timer.periodic(const Duration(seconds: 15), (_) {
      _loadMyCoords();
    });

    _loadIcons();
  }

  Future<void> _loadIcons() async {
    _partnerIconLive = await _createPartnerMarker(widget.partnerName, true);
    _partnerIconStale = await _createPartnerMarker(widget.partnerName, false);
    _myIcon = await _createMyDotMarker();
    if (mounted) setState(() {});
  }

  static Future<BitmapDescriptor> _createPartnerMarker(
      String name, bool isLive) async {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    if (isLive) {
      final Paint haloPaint = Paint()
        ..color = MilesColors.blush.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(const Offset(30, 30), 28, haloPaint);
    }

    final Paint circlePaint = Paint()
      ..shader = const LinearGradient(
        colors: [MilesColors.emberSoft, MilesColors.ember],
      ).createShader(const Rect.fromLTWH(6, 6, 48, 48));
    canvas.drawCircle(const Offset(30, 30), 24, circlePaint);

    final Paint borderPaint = Paint()
      ..color = MilesColors.ember
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(const Offset(30, 30), 24, borderPaint);

    final TextPainter textPainter = TextPainter(
      textDirection: ui.TextDirection.ltr,
      text: TextSpan(
        text: initial,
        style: const TextStyle(
            fontSize: 16, color: MilesColors.cream50, fontFamily: 'Fraunces'),
      ),
    );
    textPainter.layout();
    textPainter.paint(canvas,
        Offset(30 - textPainter.width / 2, 30 - textPainter.height / 2));

    if (isLive) {
      final Paint badgeBg = Paint()
        ..color = Colors.black.withValues(alpha: 0.6);
      final RRect badgeRect = RRect.fromRectAndRadius(
          const Rect.fromLTWH(15, 54, 30, 14), const Radius.circular(4));
      canvas.drawRRect(badgeRect, badgeBg);

      final TextPainter badgeText = TextPainter(
        textDirection: ui.TextDirection.ltr,
        text: const TextSpan(
          text: 'LIVE',
          style: TextStyle(
              fontSize: 9,
              color: MilesColors.sage,
              fontWeight: FontWeight.bold),
        ),
      );
      badgeText.layout();
      badgeText.paint(
          canvas, Offset(30 - badgeText.width / 2, 61 - badgeText.height / 2));
    }

    final ui.Image image = await pictureRecorder.endRecording().toImage(60, 70);
    final ByteData? byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  static Future<BitmapDescriptor> _createMyDotMarker() async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    final Paint circlePaint = Paint()
      ..color = MilesColors.sage.withValues(alpha: 0.9);
    canvas.drawCircle(const Offset(16, 16), 16, circlePaint);

    final Paint borderPaint = Paint()
      ..color = MilesColors.cream50
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(const Offset(16, 16), 16, borderPaint);

    final TextPainter textPainter = TextPainter(
      textDirection: ui.TextDirection.ltr,
      text: const TextSpan(
        text: 'YOU',
        style: TextStyle(
            fontSize: 9,
            color: MilesColors.cream50,
            fontWeight: FontWeight.bold),
      ),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(16 - textPainter.width / 2, 34));

    final ui.Image image = await pictureRecorder.endRecording().toImage(32, 48);
    final ByteData? byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadMyCoords();
  }

  Future<void> _loadMyCoords() async {
    if (_myLat != null && _myLon != null) return;
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
    } catch (_) {}
  }

  void _fitBoth(LatLng? partner, LatLng? me) {
    if (_map == null) return;
    if (partner != null && me != null) {
      final bounds = LatLngBounds(
        southwest: LatLng(
          partner.latitude < me.latitude ? partner.latitude : me.latitude,
          partner.longitude < me.longitude ? partner.longitude : me.longitude,
        ),
        northeast: LatLng(
          partner.latitude > me.latitude ? partner.latitude : me.latitude,
          partner.longitude > me.longitude ? partner.longitude : me.longitude,
        ),
      );
      _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
    } else if (partner != null) {
      _map!.animateCamera(CameraUpdate.newLatLngZoom(partner, 15));
    } else if (me != null) {
      _map!.animateCamera(CameraUpdate.newLatLngZoom(me, 15));
    }
  }

  @override
  void dispose() {
    _myPosPoll?.cancel();
    _distancePulse.dispose();
    super.dispose();
  }

  String _distanceText(LatLng? p, LatLng? me) {
    if (p == null || me == null) return '—';
    final m = Geolocator.distanceBetween(
        me.latitude, me.longitude, p.latitude, p.longitude);
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
    final myPoint =
        (_myLat != null && _myLon != null) ? LatLng(_myLat!, _myLon!) : null;

    if (partnerPoint != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _map?.animateCamera(CameraUpdate.newLatLng(partnerPoint));
      });
    }

    final fresh = partner?.locationUpdatedAt != null &&
        DateTime.now()
                .toUtc()
                .difference(partner!.locationUpdatedAt!.toUtc())
                .inSeconds <
            45;

    final Set<Marker> markers = {};
    if (partnerPoint != null) {
      final icon = fresh ? _partnerIconLive : _partnerIconStale;
      if (icon != null) {
        markers.add(Marker(
          markerId: const MarkerId('partner'),
          position: partnerPoint,
          icon: icon,
          anchor: const Offset(0.5, 0.5),
        ));
      }
    }
    if (myPoint != null && _myIcon != null) {
      markers.add(Marker(
        markerId: const MarkerId('me'),
        position: myPoint,
        icon: _myIcon!,
        anchor: const Offset(0.5, 0.5),
      ));
    }

    final Set<Polyline> polylines = {};
    if (partnerPoint != null && myPoint != null) {
      polylines.add(Polyline(
        polylineId: const PolylineId('line'),
        points: [myPoint, partnerPoint],
        color: MilesColors.blush.withValues(alpha: 0.55),
        width: 2,
        patterns: [PatternItem.dot, PatternItem.gap(10)],
      ));
    }

    return Scaffold(
      backgroundColor: MilesColors.night,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: partnerPoint ?? myPoint ?? const LatLng(0, 0),
                zoom: partnerPoint != null ? 15 : 3,
              ),
              markers: markers,
              polylines: polylines,
              mapType: MapType.normal,
              compassEnabled: false,
              mapToolbarEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              onMapCreated: (controller) => _map = controller,
            ),
          ),
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
                          onTap: () async {
                            if (_map != null) {
                              final double zoom = await _map!.getZoomLevel();
                              final LatLngBounds bounds =
                                  await _map!.getVisibleRegion();
                              final center = LatLng(
                                (bounds.northeast.latitude +
                                        bounds.southwest.latitude) /
                                    2,
                                (bounds.northeast.longitude +
                                        bounds.southwest.longitude) /
                                    2,
                              );
                              _map!
                                  .animateCamera(CameraUpdate.newCameraPosition(
                                CameraPosition(
                                    target: center,
                                    zoom: zoom,
                                    bearing: 0,
                                    tilt: 0),
                              ));
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
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
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
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
                    top: BorderSide(color: MilesColors.gilt, width: 0.8),
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
                                  'google.navigation:q=${partnerPoint!.latitude},${partnerPoint.longitude}');
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri);
                              } else {
                                await launchUrl(Uri.parse(
                                    'https://maps.google.com/?q=${partnerPoint.latitude},${partnerPoint.longitude}'));
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
                              final dist = _distanceText(partnerPoint, myPoint);
                              try {
                                await ChatRepository.sendText(
                                  widget.coupleId,
                                  "I'm $dist away, heading your way 💕",
                                );
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            "Couldn't send — try again.",),),
                                  );
                                }
                                return;
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Sent your ETA 💌')),
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
        // scrim over the map tiles behind it
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: MilesColors.surface1,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: MilesColors.gilt, width: 0.8),
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
