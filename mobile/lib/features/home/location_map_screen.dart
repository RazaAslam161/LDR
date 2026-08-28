import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
// `show`, because geolocator's Position collides with Mapbox's geotypes one.
import 'package:geolocator/geolocator.dart'
    show Geolocator, LocationAccuracy, LocationSettings;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart'
    hide LocationSettings;
import 'package:miles/core/media/map_token.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:url_launcher/url_launcher.dart';

/// A bare coordinate pair for the screen's own logic — Mapbox's Point is a
/// GeoJSON object and Google's LatLng is gone with its SDK.
typedef _Geo = ({double lat, double lon});

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
  MapboxMap? _map;
  PointAnnotationManager? _points;
  PolylineAnnotationManager? _lines;
  PointAnnotation? _partnerPin;
  PointAnnotation? _myPin;
  PolylineAnnotation? _line;
  bool _partnerPinFresh = true;
  _Geo? _followedAt;

  bool _ready = false;
  bool _tokenMissing = false;

  late final AnimationController _distancePulse;

  double? _myLat;
  double? _myLon;
  Timer? _myPosPoll;

  Uint8List? _partnerIconLive;
  Uint8List? _partnerIconStale;
  Uint8List? _myIcon;

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
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final token = await MapToken.ensure();
    if (!mounted) return;
    if (token == null) {
      setState(() => _tokenMissing = true);
      return;
    }
    MapboxOptions.setAccessToken(token);
    setState(() => _ready = true);
  }

  Future<void> _loadIcons() async {
    _partnerIconLive = await _createPartnerMarker(widget.partnerName, true);
    _partnerIconStale = await _createPartnerMarker(widget.partnerName, false);
    _myIcon = await _createMyDotMarker();
    if (mounted) setState(() {});
  }

  static Future<Uint8List> _createPartnerMarker(
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
    return byteData!.buffer.asUint8List();
  }

  static Future<Uint8List> _createMyDotMarker() async {
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
    return byteData!.buffer.asUint8List();
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

  Future<void> _fitBoth(_Geo? partner, _Geo? me) async {
    final map = _map;
    if (map == null) return;
    if (partner != null && me != null) {
      final bounds = CoordinateBounds(
        southwest: Point(coordinates: Position(
          partner.lon < me.lon ? partner.lon : me.lon,
          partner.lat < me.lat ? partner.lat : me.lat,
        ),),
        northeast: Point(coordinates: Position(
          partner.lon > me.lon ? partner.lon : me.lon,
          partner.lat > me.lat ? partner.lat : me.lat,
        ),),
        infiniteBounds: false,
      );
      final cam = await map.cameraForCoordinateBounds(
        bounds,
        MbxEdgeInsets(top: 80, left: 80, bottom: 80, right: 80),
        null, null, null, null,
      );
      await map.flyTo(cam, MapAnimationOptions(duration: 700));
    } else {
      final one = partner ?? me;
      if (one == null) return;
      await map.flyTo(
        CameraOptions(
          center: Point(coordinates: Position(one.lon, one.lat)),
          zoom: 15,
        ),
        MapAnimationOptions(duration: 700),
      );
    }
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
    await map.compass.updateSettings(CompassSettings(enabled: false));
    _points = await map.annotations.createPointAnnotationManager();
    _lines = await map.annotations.createPolylineAnnotationManager();
    await _syncAnnotations();
  }

  /// Push the current positions at the imperative annotation layer. Cheap to
  /// call from a post-frame: every branch no-ops when nothing moved.
  Future<void> _syncAnnotations() async {
    final points = _points;
    final lines = _lines;
    if (points == null || lines == null) return;

    final presence = ref.read(partnerPresenceProvider);
    final partner = presence?.isSharingLive ?? false ? presence : null;
    final fresh = partner?.locationUpdatedAt != null &&
        DateTime.now()
                .toUtc()
                .difference(partner!.locationUpdatedAt!.toUtc())
                .inSeconds <
            45;

    if (partner?.latitude != null && partner?.longitude != null) {
      final geom = Point(
          coordinates: Position(partner!.longitude!, partner.latitude!),);
      final icon = fresh ? _partnerIconLive : _partnerIconStale;
      if (icon != null) {
        // Freshness swaps the ICON, and an annotation's image can only be set
        // at creation — so a staleness flip recreates the pin.
        if (_partnerPin != null && _partnerPinFresh != fresh) {
          await points.delete(_partnerPin!);
          _partnerPin = null;
        }
        if (_partnerPin == null) {
          _partnerPin = await points.create(PointAnnotationOptions(
            geometry: geom,
            image: icon,
            iconAnchor: IconAnchor.CENTER,
          ),);
          _partnerPinFresh = fresh;
        } else {
          _partnerPin!.geometry = geom;
          await points.update(_partnerPin!);
        }
      }
    }

    if (_myLat != null && _myLon != null && _myIcon != null) {
      final geom = Point(coordinates: Position(_myLon!, _myLat!));
      if (_myPin == null) {
        _myPin = await points.create(PointAnnotationOptions(
          geometry: geom,
          image: _myIcon,
          iconAnchor: IconAnchor.CENTER,
        ),);
      } else {
        _myPin!.geometry = geom;
        await points.update(_myPin!);
      }

      if (partner?.latitude != null) {
        final lineGeom = LineString(coordinates: [
          Position(_myLon!, _myLat!),
          Position(partner!.longitude!, partner.latitude!),
        ],);
        if (_line == null) {
          // Solid at 0.55 where Google drew dots — this SDK has no
          // per-annotation dash array, and the faint thread reads the same.
          _line = await lines.create(PolylineAnnotationOptions(
            geometry: lineGeom,
            lineColor: MilesColors.blush.toARGB32(),
            lineOpacity: 0.55,
            lineWidth: 2,
          ),);
        } else {
          _line!.geometry = lineGeom;
          await lines.update(_line!);
        }
      }
    }
  }

  @override
  void dispose() {
    _myPosPoll?.cancel();
    _distancePulse.dispose();
    super.dispose();
  }

  String _distanceText(_Geo? p, _Geo? me) {
    if (p == null || me == null) return '—';
    final m =
        Geolocator.distanceBetween(me.lat, me.lon, p.lat, p.lon);
    if (m < 1000) return '${m.round()} m apart';
    return '${(m / 1000).toStringAsFixed(1)} km apart';
  }

  @override
  Widget build(BuildContext context) {
    final presence = ref.watch(partnerPresenceProvider);
    final partner = presence?.isSharingLive ?? false ? presence : null;
    final _Geo? partnerPoint =
        partner?.latitude != null && partner?.longitude != null
            ? (lat: partner!.latitude!, lon: partner.longitude!)
            : null;
    final _Geo? myPoint =
        (_myLat != null && _myLon != null) ? (lat: _myLat!, lon: _myLon!) : null;

    if (partnerPoint != null && partnerPoint != _followedAt) {
      // Follow only when she actually moved — re-centring on every rebuild
      // (the Google version's behaviour) fought the user's own pan.
      _followedAt = partnerPoint;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_map?.easeTo(
          CameraOptions(
            center: Point(
                coordinates: Position(partnerPoint.lon, partnerPoint.lat),),
          ),
          MapAnimationOptions(duration: 600),
        ),);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAnnotations());

    return Scaffold(
      backgroundColor: MilesColors.night,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: !_ready
                ? ColoredBox(
                    color: MilesColors.night,
                    child: Center(
                      child: _tokenMissing
                          ? const Padding(
                              padding: EdgeInsets.all(32),
                              child: Text(
                                'The map needs its Mapbox token stored '
                                'server-side. Everything else here still '
                                'works.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: MilesColors.taupe, fontSize: 13,),
                              ),
                            )
                          : const SizedBox(
                              width: 24,
                              height: 24,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                    ),
                  )
                : MapWidget(
                    key: const ValueKey('location-map'),
                    cameraOptions: CameraOptions(
                      center: Point(
                        coordinates: Position(
                          (partnerPoint ?? myPoint)?.lon ?? 0,
                          (partnerPoint ?? myPoint)?.lat ?? 0,
                        ),
                      ),
                      zoom: partnerPoint != null ? 15 : 3,
                    ),
                    styleUri: MapboxStyles.DARK,
                    onMapCreated: _onMapCreated,
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
                            final map = _map;
                            if (map == null) return;
                            // Same view, north-up and flat — the camera
                            // already knows where it is.
                            final cam = await map.getCameraState();
                            await map.easeTo(
                              CameraOptions(
                                center: cam.center,
                                zoom: cam.zoom,
                                bearing: 0,
                                pitch: 0,
                              ),
                              MapAnimationOptions(duration: 500),
                            );
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
                                  'google.navigation:q=${partnerPoint!.lat},${partnerPoint.lon}');
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(uri);
                              } else {
                                await launchUrl(Uri.parse(
                                    'https://maps.google.com/?q=${partnerPoint.lat},${partnerPoint.lon}'));
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
