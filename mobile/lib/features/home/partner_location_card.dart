import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
// `show`, because geolocator's Position collides with Mapbox's geotypes
// Position — and this file only ever wants the distance helper.
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/media/map_token.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/home/partner_sentence.dart';
import 'package:miles/features/home/world_map_screen.dart';

/// Live partner location on the dashboard: a small dark Mapbox map with the
/// partner's marker easing to each new fix, "updated Xs ago", and the distance
/// between you.
///
/// Mapbox, not Google — the Google billing account is closed for good
/// (BRAIN §4b), so every Google surface rendered an unauthorised grey void.
/// The token comes from the server at runtime (MapToken), same as the world
/// map, so this card works on every install without a key in the APK.
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
  MapboxMap? _map;
  PointAnnotationManager? _points;
  PolylineAnnotationManager? _lines;
  PointAnnotation? _partnerPin;
  PointAnnotation? _myPin;
  PolylineAnnotation? _line;

  Uint8List? _partnerIcon;
  Uint8List? _myIcon;

  bool _ready = false;
  bool _tokenMissing = false;

  @override
  void initState() {
    super.initState();
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
    _partnerIcon = await _createAvatarMarker(
        widget.partnerName, MilesColors.blush, MilesColors.cream50);
    _myIcon = await _createMyDotMarker();
    if (mounted) setState(() {});
  }

  /// The same canvas drawing the Google version used — only the return type
  /// changed: Mapbox point annotations take the PNG bytes directly.
  static Future<Uint8List> _createAvatarMarker(
      String name, Color color, Color textColor) async {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '♥';
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3);
    canvas.drawOval(const Rect.fromLTWH(18, 44, 12, 4), shadowPaint);

    final circlePaint = Paint()..color = color;
    canvas.drawCircle(const Offset(24, 24), 14, circlePaint);

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(const Offset(24, 24), 14, borderPaint);

    final textPainter = TextPainter(
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

    final image = await pictureRecorder.endRecording().toImage(48, 48);
    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  static Future<Uint8List> _createMyDotMarker() async {
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);

    final circlePaint = Paint()..color = MilesColors.sage;
    canvas.drawCircle(const Offset(13, 13), 10, circlePaint);

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(const Offset(13, 13), 10, borderPaint);

    final image = await pictureRecorder.endRecording().toImage(26, 26);
    final byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    // Every line here is a platform-channel call into the Mapbox SDK, and each
    // one is a MissingPluginException away from leaving `_points` null — at
    // which point _syncAnnotations early-returns forever and the card paints a
    // working map with no partner on it and nothing to say why. Five reports
    // across builds 70, 74 and 76 arrived exactly this way, from
    // createPointAnnotationManager and createPolylineAnnotationManager, with
    // no try/catch anywhere on the path.
    try {
      await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
      await map.compass.updateSettings(CompassSettings(enabled: false));
      _points = await map.annotations.createPointAnnotationManager();
      _lines = await map.annotations.createPolylineAnnotationManager();
      await _syncAnnotations();
      if (mounted && _mapBroken) setState(() => _mapBroken = false);
    } catch (e, st) {
      ErrorReporter.report(e, st, kind: 'map-annotations');
      // Said on the card rather than swallowed: a partner who IS sharing and
      // simply cannot be drawn is the one case indistinguishable from a
      // partner who has stopped sharing, and those need opposite reactions.
      if (mounted) setState(() => _mapBroken = true);
    }
  }

  /// The map surface came up but its annotation layer did not, so nothing can
  /// be drawn on it however good the location data is.
  bool _mapBroken = false;

  /// Mapbox annotations are imperative where Google's were declarative: the
  /// build method computes the positions and this pushes them at the map.
  Future<void> _syncAnnotations() async {
    final points = _points;
    final lines = _lines;
    if (points == null || lines == null) return;
    final p = widget.partner;
    if (p == null || !p.isSharingLive || p.latitude == null) return;

    final partnerPoint =
        Point(coordinates: Position(p.longitude!, p.latitude!));
    final icon = _partnerIcon;
    if (icon != null) {
      if (_partnerPin == null) {
        _partnerPin = await points.create(PointAnnotationOptions(
          geometry: partnerPoint,
          image: icon,
          // The drawn marker carries its ground shadow at the bottom edge —
          // same reason the Google anchor was (0.5, 0.9).
          iconAnchor: IconAnchor.BOTTOM,
        ),);
      } else {
        _partnerPin!.geometry = partnerPoint;
        await points.update(_partnerPin!);
      }
    }

    final myIcon = _myIcon;
    if (widget.myLat != null && widget.myLon != null && myIcon != null) {
      final myPoint =
          Point(coordinates: Position(widget.myLon!, widget.myLat!));
      if (_myPin == null) {
        _myPin = await points.create(PointAnnotationOptions(
          geometry: myPoint,
          image: myIcon,
          iconAnchor: IconAnchor.CENTER,
        ),);
      } else {
        _myPin!.geometry = myPoint;
        await points.update(_myPin!);
      }

      final lineGeom = LineString(coordinates: [
        Position(widget.myLon!, widget.myLat!),
        Position(p.longitude!, p.latitude!),
      ],);
      if (_line == null) {
        // Solid at 0.55 opacity where Google drew dots — per-annotation
        // dash arrays do not exist in this SDK, and a faint solid thread
        // reads the same at card size.
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
        final point = Point(coordinates: Position(p.longitude!, p.latitude!));
        unawaited(_map?.easeTo(CameraOptions(center: point),
            MapAnimationOptions(duration: 600),),);
        unawaited(_syncAnnotations());
      }
    }
  }

  void _recenter() {
    final p = widget.partner;
    if (p == null || !p.isSharingLive) return;
    unawaited(_map?.easeTo(
      CameraOptions(
        center: Point(coordinates: Position(p.longitude!, p.latitude!)),
        zoom: 15.5,
      ),
      MapAnimationOptions(duration: 600),
    ),);
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

  /// The 210px slot when the map cannot draw: the server token is absent or
  /// this fetch failed. The card's words and distance still work, and the tap
  /// still leads to the full screen (which explains the setup).
  Widget _mapFallback() => Container(
        height: 210,
        width: double.infinity,
        color: MilesColors.night,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.public_off, color: MilesColors.taupe, size: 28),
            const SizedBox(height: 8),
            Text(
              _tokenMissing
                  ? 'The map needs its server token.'
                  : 'Loading the map…',
              style: const TextStyle(color: MilesColors.taupe, fontSize: 12),
            ),
          ],
        ),
      );

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

    final dist = _distanceText();
    // A new fix arriving is a rebuild; push it at the imperative annotation
    // layer once the frame settles.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncAnnotations());

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
                          lat: p.latitude!,
                          lon: p.longitude!,
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
            SizedBox(
              height: 210,
              child: GestureDetector(
                onTap: () => context.push('/app/location-map', extra: {
                  'coupleId': widget.coupleId,
                  'partnerName': widget.partnerName,
                }),
                child: AbsorbPointer(
                  child: Stack(
                    children: [
                      if (!_ready)
                        Positioned.fill(child: _mapFallback())
                      else
                        Positioned.fill(
                          child: MapWidget(
                            key: const ValueKey('partner-card-map'),
                            cameraOptions: CameraOptions(
                              center: Point(
                                coordinates:
                                    Position(p.longitude!, p.latitude!),
                              ),
                              zoom: 15.5,
                            ),
                            // Dark vector style: matches the app, and cheap —
                            // the card is glanced at, not explored.
                            styleUri: MapboxStyles.DARK,
                            onMapCreated: _onMapCreated,
                          ),
                        ),
                      // The map drew but nothing can be placed on it. Said out
                      // loud because an empty map and a partner who stopped
                      // sharing look identical, and only one of them is worth
                      // reopening the screen for.
                      if (_mapBroken)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              // scrim over the map tiles behind it
                              color: Colors.black.withValues(alpha: 0.55),
                              child: const Text(
                                "Map didn't load fully — reopen to retry",
                                style: TextStyle(
                                    color: MilesColors.cream50,
                                    fontSize: 11,
                                    fontFamily: 'Inter'),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            // scrim over the map tiles behind it
                            color: Colors.black.withValues(alpha: 0.45),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.fullscreen_rounded,
                                    color: MilesColors.cream50, size: 14),
                                SizedBox(width: 4),
                                Text(
                                  'Full screen',
                                  style: TextStyle(
                                      color: MilesColors.cream50,
                                      fontSize: 11,
                                      fontFamily: 'Inter'),
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
