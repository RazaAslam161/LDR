import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:miles/core/media/map_token.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/ui/theme.dart';


/// The full 3D map: real satellite imagery draped over real elevation, with
/// buildings standing out of it, under a sky.
///
/// Behind a deliberate tap, never on Home. Everything else in this app draws
/// itself from data the couple already has; this screen is the one place that
/// asks a third party for anything, and it should be a thing the user chose
/// rather than a thing that happened while they were looking at something else.
///
/// Why Mapbox and not MapLibre: MapLibre *Native* — the mobile engine — has no
/// 3D terrain and no sky. Only MapLibre GL JS, the browser build, does, which
/// is why the WebView version of this screen had terrain and a native port of
/// it would not have. That terrain branch is stalled upstream.
class WorldMapScreen extends ConsumerStatefulWidget {
  const WorldMapScreen({
    required this.lat,
    required this.lon,
    required this.name,
    super.key,
  });

  final double lat;
  final double lon;
  final String name;

  @override
  ConsumerState<WorldMapScreen> createState() => _WorldMapScreenState();
}

class _WorldMapScreenState extends ConsumerState<WorldMapScreen> {
  MapboxMap? _map;
  CircleAnnotationManager? _markers;
  CircleAnnotation? _partnerPin;

  /// Where the pin currently sits, so a presence tick that has not actually
  /// moved does not rebuild the annotation on every rebuild.
  double? _pinLat;
  double? _pinLon;

  bool _ready = false;
  bool _tokenMissing = false;

  /// Tilt. Past ~70 the horizon fills half the screen with terrain nobody is
  /// looking at, and every one of those tiles is fetched and drawn.
  static const _pitch = 62.0;
  static const _zoom = 16.8;
  static const _bearing = 28.0;

  @override
  void initState() {
    super.initState();
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

  /// Draw or move the partner's pin.
  ///
  /// The screen was centring the camera on a position and drawing nothing, so
  /// the partner was wherever the middle of the screen happened to be — and the
  /// moment you panned, nothing on the map said where she actually was. The
  /// basic map has always had this; the 3D one never did.
  Future<void> _placePartner(double lat, double lon, {bool recentre = false}) async {
    final markers = _markers;
    if (markers == null) return;
    if (_pinLat == lat && _pinLon == lon && _partnerPin != null) return;
    _pinLat = lat;
    _pinLon = lon;

    final point = Point(coordinates: Position(lon, lat));
    if (_partnerPin == null) {
      // A CIRCLE, not an icon.
      //
      // This drew `iconImage: 'dot-11'` — a Maki sprite name that ships with
      // Mapbox Streets v11. This screen loads the STANDARD style (it configures
      // `basemap`/`lightPreset`/`show3dObjects`, which only Standard has), and
      // Standard carries no Maki sprite. A PointAnnotation whose iconImage is
      // missing from the style renders NOTHING — no error, no placeholder, no
      // log. So the annotation was created, the camera flew to her, and the map
      // was empty: the exact symptom, with nothing anywhere to explain it.
      //
      // A circle annotation is drawn by the renderer itself, so it depends on
      // no sprite, no bundled asset and no style choice — it cannot silently
      // vanish the next time the basemap changes.
      _partnerPin = await markers.create(CircleAnnotationOptions(
        geometry: point,
        circleRadius: 8,
        circleColor: MilesColors.blush.toARGB32(),
        // A white ring, the way every map marks a person: the fill alone
        // disappears against terrain of a similar tone, and satellite imagery
        // has every tone.
        circleStrokeWidth: 3,
        circleStrokeColor: 0xFFFFFFFF,
      ),);
    } else {
      _partnerPin!.geometry = point;
      await markers.update(_partnerPin!);
    }

    if (recentre) {
      await _map?.flyTo(
        CameraOptions(center: point, zoom: _zoom, pitch: _pitch,
            bearing: _bearing,),
        MapAnimationOptions(duration: 900),
      );
    }
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    _markers = await map.annotations.createCircleAnnotationManager();
    await _placePartner(widget.lat, widget.lon);
    // The SDK's own logo and attribution stay. They are a licence condition,
    // and the previous version of this screen set attributionControl:false —
    // which is not a style choice, it is using someone's imagery against their
    // terms.
    await map.scaleBar.updateSettings(ScaleBarSettings(enabled: false));
    await map.compass.updateSettings(CompassSettings(enabled: false));

    // 'dusk' rather than 'day': this app is dark everywhere else, and a
    // noon-lit satellite view dropped into it looks like a different product.
    // Terrain, sky and fog come with the Standard style — they are not layers
    // assembled here, which is the whole reason for choosing it.
    await map.style.setStyleImportConfigProperty(
      'basemap',
      'lightPreset',
      'dusk',
    );
    await map.style.setStyleImportConfigProperty(
      'basemap',
      'show3dObjects',
      true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Follow her. The screen took a fixed lat/lon at construction, so it showed
    // where she was when it opened and never moved again — the basic map
    // tracked movement and this did not.
    ref.listen<Presence?>(partnerPresenceProvider, (_, next) {
      final lat = next?.latitude;
      final lon = next?.longitude;
      if (lat == null || lon == null) return;
      unawaited(_placePartner(lat, lon, recentre: true));
    });

    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        backgroundColor: MilesColors.night,
        title: Text(widget.name),
      ),
      body: _tokenMissing
          ? const _NotConfigured()
          : !_ready
              ? const Center(
                  child: CircularProgressIndicator(color: MilesColors.ember),
                )
              : MapWidget(
                  key: const ValueKey('world-map'),
                  // Standard is the only Mapbox style that carries terrain,
                  // sky, fog and 3D buildings as one coherent scene rather than
                  // as layers to be assembled and kept in sync by hand.
                  styleUri: MapboxStyles.STANDARD_SATELLITE,
                  cameraOptions: CameraOptions(
                    center: Point(
                      coordinates: Position(widget.lon, widget.lat),
                    ),
                    zoom: _zoom,
                    pitch: _pitch,
                    bearing: _bearing,
                  ),
                  onMapCreated: _onMapCreated,
                ),
    );
  }
}

/// Shown when no Mapbox token has been configured.
///
/// A grey rectangle is what every app does here, and it makes a configuration
/// gap look like a bug in the app. This says which it is.
class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.public_off, color: MilesColors.taupe, size: 40),
              SizedBox(height: 16),
              Text(
                'The world map is not set up yet',
                style: TextStyle(color: MilesColors.cream50, fontSize: 15),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                'It needs a Mapbox token stored server-side. Everything else '
                'in the app works without it.',
                style: TextStyle(color: MilesColors.taupe, fontSize: 12.5),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
