import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart'; // For Distance
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mb;
import 'package:miles/core/data/models.dart';
import 'package:miles/core/media/map_token.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/home/partner_sentence.dart';
import 'package:miles/features/home/world_map_screen.dart';

/// Live partner location on the dashboard. Shows a Google Map
/// with the partner's marker that animates to each new fix, "updated Xs ago",
/// and the distance between you.
class PartnerLocationCard extends StatefulWidget {
  const PartnerLocationCard({
    required this.partner,
    required this.partnerName,
    required this.coupleId,
    super.key,
    this.partnerProfile,
    this.myTimezone,
    this.myLat,
    this.myLon,
  });

  final Presence? partner;
  final String partnerName;
  final String coupleId;
  final Profile? partnerProfile;
  final String? myTimezone;
  final double? myLat;
  final double? myLon;

  @override
  State<PartnerLocationCard> createState() => _PartnerLocationCardState();
}

class _PartnerLocationCardState extends State<PartnerLocationCard> {
  GoogleMapController? _mapController;
  BitmapDescriptor? _partnerIcon;
  BitmapDescriptor? _myIcon;

  @override
  void initState() {
    super.initState();
    _loadIcons();
  }

  Future<void> _loadIcons() async {
    _partnerIcon = await _createAvatarMarker(
        widget.partnerName, MilesColors.blush, MilesColors.cream50);
    _myIcon = await _createMyDotMarker();
    if (mounted) setState(() {});
  }

  static Future<BitmapDescriptor> _createAvatarMarker(
      String name, Color color, Color textColor) async {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    final Paint shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3);
    canvas.drawOval(const Rect.fromLTWH(18, 44, 12, 4), shadowPaint);

    final Paint circlePaint = Paint()..color = color;
    canvas.drawCircle(const Offset(24, 24), 14, circlePaint);

    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(const Offset(24, 24), 14, borderPaint);

    final TextPainter textPainter = TextPainter(
      textDirection: ui.TextDirection.ltr,
      text: TextSpan(
        text: initial,
        style: TextStyle(
            fontSize: 14, color: textColor, fontWeight: FontWeight.bold),
      ),
    );
    textPainter.layout();
    textPainter.paint(canvas,
        Offset(24 - textPainter.width / 2, 24 - textPainter.height / 2));

    final ui.Image image = await pictureRecorder.endRecording().toImage(48, 48);
    final ByteData? byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  static Future<BitmapDescriptor> _createMyDotMarker() async {
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    final Paint circlePaint = Paint()..color = MilesColors.sage;
    canvas.drawCircle(const Offset(13, 13), 10, circlePaint);

    final Paint borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(const Offset(13, 13), 10, borderPaint);

    final ui.Image image = await pictureRecorder.endRecording().toImage(26, 26);
    final ByteData? byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
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
        _mapController?.animateCamera(
            CameraUpdate.newLatLng(LatLng(p.latitude!, p.longitude!)));
      }
    }
  }

  void _recenter() {
    final p = widget.partner;
    if (p == null || !p.isSharingLive) return;
    _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(p.latitude!, p.longitude!), 15.5));
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
    final m = Geolocator.distanceBetween(
        widget.myLat!, widget.myLon!, p.latitude!, p.longitude!);
    if (m < 950) return '${m.round()} m apart';
    final km = m / 1000;
    return '${NumberFormat.decimalPattern().format(km.round())} km apart';
  }

  Widget _sentence() {
    final s = partnerSentence(
      presence: widget.partner,
      partner: widget.partnerProfile,
      myTimezone: widget.myTimezone,
      partnerName: widget.partnerName,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        s.text,
        style: TextStyle(
          color: s.confident ? MilesColors.cream50 : MilesColors.taupe,
          fontSize: 14,
          height: 1.3,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.partner;

    if (p != null && p.isSharingCity) {
      return SurfacePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _sentence(),
            Row(
              children: [
                const Icon(Icons.location_city_outlined,
                    color: MilesColors.gilt, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${widget.partnerName} is in ${p.locationLabel}',
                    style: const TextStyle(
                        color: MilesColors.cream50, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (p == null || !p.isSharingLive) {
      return SurfacePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _sentence(),
            Row(
              children: [
                const Icon(Icons.location_off_outlined,
                    color: MilesColors.taupe, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "${widget.partnerName} isn't sharing location right now",
                    style:
                        const TextStyle(color: MilesColors.taupe, fontSize: 13),
                  ),
                ),
              ],
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

    final Set<Marker> markers = {};
    if (_partnerIcon != null) {
      markers.add(Marker(
        markerId: const MarkerId('partner'),
        position: point,
        icon: _partnerIcon!,
        anchor: const Offset(0.5, 0.9),
      ));
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
    if (myPoint != null) {
      polylines.add(Polyline(
        polylineId: const PolylineId('line'),
        points: [myPoint, point],
        color: MilesColors.blush.withValues(alpha: 0.55),
        width: 2,
        patterns: [PatternItem.dot, PatternItem.gap(10)],
      ));
    }

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
                    icon: const Icon(Icons.travel_explore,
                        color: MilesColors.gilt, size: 20),
                    tooltip: 'Open the world map',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => WorldMapScreen(
                          lat: point.latitude,
                          lon: point.longitude,
                          name: widget.partnerName,
                        ),
                      ),
                    ),
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
            // The card used to mount a LIVE map here, so merely opening Home
            // streamed tile requests centred on your partner to a third party
            // before you touched anything. The map is worth having; having it
            // render unasked on the home screen of an app whose whole premise
            // is that nothing leaks is not.
            GestureDetector(
              onTap: () => context.push('/app/location-map', extra: {
                'coupleId': widget.coupleId,
                'partnerName': widget.partnerName,
              }),
              child: _HomeMiniMap(
                lat: p.latitude!,
                lon: p.longitude!,
                label: p.locationLabel,
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

/// Home's door to the map, in place of a live one.
///
/// Says where she is in words. The sentence above it already says whether you
/// can talk to her, which is the question people actually open this app to ask
/// — and neither of them contacts anybody. The map itself is one tap away,
/// where it is a thing the user chose rather than a thing that happened while
/// they were looking at Home.
class _HomeMiniMap extends StatefulWidget {
  const _HomeMiniMap({required this.lat, required this.lon, this.label});

  final double lat;
  final double lon;
  final String? label;

  @override
  State<_HomeMiniMap> createState() => _HomeMiniMapState();
}

class _HomeMiniMapState extends State<_HomeMiniMap> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final token = await MapToken.ensure();
    if (!mounted || token == null) return;
    mb.MapboxOptions.setAccessToken(token);
    setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 190,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_ready)
              // AbsorbPointer so a drag scrolls Home instead of panning a map
              // the user cannot see enough of to navigate. Tapping opens the
              // full screen one, which is where panning belongs.
              AbsorbPointer(
                child: mb.MapWidget(
                  key: const ValueKey('home-mini-map'),
                  styleUri: mb.MapboxStyles.STANDARD_SATELLITE,
                  cameraOptions: mb.CameraOptions(
                    center: mb.Point(
                      coordinates: mb.Position(widget.lon, widget.lat),
                    ),
                    zoom: 14.5,
                    pitch: 45,
                  ),
                ),
              )
            else
              const ColoredBox(color: MilesColors.surface1),
            if (widget.label?.isNotEmpty ?? false)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // scrim over the map behind it
                    color: MilesColors.night.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(
                      widget.label!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: MilesColors.cream50,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

