import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// A progressive map view: photorealistic 3D when the JavaScript API can
/// render, with the native map available as an immediate, reliable fallback.
class WorldMapScreen extends StatefulWidget {
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
  State<WorldMapScreen> createState() => _WorldMapScreenState();
}

class _WorldMapScreenState extends State<WorldMapScreen> {
  late final WebViewController _controller;
  late final String _apiKey;
  late final String _mapId;

  bool _loading3d = true;
  bool _show2d = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _apiKey = dotenv.maybeGet('GOOGLE_MAPS_3D_KEY') ??
        dotenv.maybeGet('GOOGLE_MAPS_API_KEY') ??
        '';
    _mapId = dotenv.maybeGet('GOOGLE_MAPS_3D_MAP_ID') ?? '';

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(MilesColors.night)
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? false) {
              _reportFailure('The 3D map page could not load.');
            }
          },
        ),
      )
      ..setOnConsoleMessage((message) {
        debugPrint('3D map: ${message.message}');
      })
      ..addJavaScriptChannel(
        'MapStatus',
        onMessageReceived: (message) {
          final status = message.message;
          if (status == 'ready') {
            if (mounted) {
              setState(() {
                _loading3d = false;
                _error = null;
              });
            }
            return;
          }
          if (status.startsWith('error:')) {
            _reportFailure(status.substring('error:'.length));
          }
        },
      );

    _load3dMap();
  }

  void _load3dMap() {
    if (_apiKey.isEmpty) {
      _reportFailure('3D maps have not been configured for this build.');
      return;
    }
    _controller.loadHtmlString(_html());
  }

  void _reportFailure(String message) {
    if (!mounted) return;
    setState(() {
      _loading3d = false;
      _error = message;
    });
  }

  String _html() {
    final name = jsonEncode(widget.name);
    final initial = jsonEncode(
      widget.name.isEmpty ? '♥' : widget.name.characters.first.toUpperCase(),
    );
    final apiKey = jsonEncode(_apiKey);
    final mapId = jsonEncode(_mapId);

    return '''
<!doctype html>
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <style>
      html, body, #map { height: 100%; width: 100%; margin: 0; background: #0b0f16; overflow: hidden; }
      gmp-map-3d { height: 100%; width: 100%; display: block; }
      .marker { display:flex; flex-direction:column; align-items:center; transform:translateY(-50%); }
      .pin { width:32px; height:32px; border-radius:50%; display:flex; align-items:center; justify-content:center; color:#fff; font:700 16px serif; background:linear-gradient(135deg,#ff7b54,#ff5f30); border:2px solid white; box-shadow:0 4px 8px rgba(0,0,0,.4); }
      .label { margin-top:4px; padding:4px 8px; border-radius:8px; color:#fff; background:rgba(0,0,0,.7); font:700 12px sans-serif; white-space:nowrap; }
    </style>
  </head>
  <body>
    <div id="map"></div>
    <script>
      const apiKey = $apiKey;
      const mapId = $mapId;
      const partnerName = $name;
      const initial = $initial;
      const status = (value) => MapStatus.postMessage(value);

      async function initMap() {
        try {
          const { Map3DElement, Marker3DElement } = await google.maps.importLibrary('maps3d');
          const map = new Map3DElement({
            center: { lat: ${widget.lat}, lng: ${widget.lon}, altitude: 50 },
            heading: 25,
            tilt: 65,
            range: 400,
            mode: 'HYBRID',
            defaultUIHidden: true,
            ...(mapId ? { mapId } : {}),
          });
          map.addEventListener('gmp-error', (event) => status('error:' + (event.message || 'Google Maps could not render the 3D scene.')));
          map.addEventListener('gmp-map-id-error', () => status('error:The configured 3D map ID is not valid.'));

          const marker = new Marker3DElement({
            position: { lat: ${widget.lat}, lng: ${widget.lon}, altitude: 50 },
          });
          const content = document.createElement('div');
          content.className = 'marker';
          const pin = document.createElement('div');
          pin.className = 'pin';
          pin.textContent = initial;
          const label = document.createElement('div');
          label.className = 'label';
          label.textContent = partnerName;
          content.append(pin, label);
          marker.append(content);
          map.append(marker);
          document.getElementById('map').append(map);
          status('ready');
        } catch (error) {
          status('error:' + (error && error.message ? error.message : 'Google Maps could not initialize.'));
        }
      }

      // Google's official inline bootstrap loader.
      //
      // The previous version appended a plain <script src=...&loading=async>
      // and called initMap from script.onload. With loading=async the API does
      // NOT define google.maps.importLibrary synchronously — the bootstrap
      // below installs it as a shim that queues calls until the real library
      // lands. Loading the tag directly races that setup, which is exactly the
      // "google.maps.importLibrary is not a function" the device reported.
      (g => {
        var h, a, k, p = "The Google Maps JavaScript API", c = "google",
            l = "importLibrary", q = "__ib__", m = document, b = window;
        b = b[c] || (b[c] = {});
        var d = b.maps || (b.maps = {}), r = new Set(), e = new URLSearchParams(),
            u = () => h || (h = new Promise(async (f, n) => {
              await (a = m.createElement("script"));
              e.set("libraries", [...r] + "");
              for (k in g) e.set(k.replace(/[A-Z]/g, t => "_" + t[0].toLowerCase()), g[k]);
              e.set("callback", c + ".maps." + q);
              a.src = "https://maps." + c + "apis.com/maps/api/js?" + e;
              d[q] = f;
              a.onerror = () => h = n(Error(p + " could not load."));
              m.head.append(a);
            }));
        d[l] ? console.warn(p + " only loads once. Ignoring:", g)
             : d[l] = (f, ...n) => r.add(f) && u().then(() => d[l](f, ...n));
      })({ key: apiKey, v: "alpha" });

      initMap().catch(e => status('error:' + (e && e.message ? e.message : 'Google Maps could not load.')));
    </script>
  </body>
</html>''';
  }

  @override
  void dispose() {
    // Tear the page down explicitly. A WebView is a platform view living
    // outside the Flutter tree, so leaving it loaded kept Google's "Oops!
    // Something went wrong" card alive and compositing over whatever screen
    // came next — it turned up on the Afterglow form, which has nothing to do
    // with maps. Navigating away must actually end the page, not just stop
    // showing it.
    _controller.loadRequest(Uri.parse('about:blank')).ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = LatLng(widget.lat, widget.lon);
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        backgroundColor: MilesColors.night,
        title: Text('${widget.name} (3D)'),
      ),
      body: Stack(
        children: [
          if (_show2d)
            GoogleMap(
              initialCameraPosition: CameraPosition(target: position, zoom: 16),
              mapType: MapType.hybrid,
              markers: {
                Marker(
                  markerId: const MarkerId('partner'),
                  position: position,
                  infoWindow: InfoWindow(title: widget.name),
                ),
              },
              mapToolbarEnabled: false,
              zoomControlsEnabled: false,
            )
          else
            WebViewWidget(controller: _controller),
          if (_loading3d && !_show2d)
            const Center(
              child: CircularProgressIndicator(color: MilesColors.ember),
            ),
          if (_error != null && !_show2d)
            _MapError(
              message: _error!,
              onRetry: () {
                setState(() {
                  _error = null;
                  _loading3d = true;
                });
                _load3dMap();
              },
              onOpen2d: () => setState(() => _show2d = true),
            ),
          if (_show2d)
            Positioned(
              right: 16,
              bottom: 16,
              child: FilledButton.icon(
                onPressed: () => setState(() {
                  _show2d = false;
                  _loading3d = true;
                  _error = null;
                }),
                icon: const Icon(Icons.threed_rotation_outlined),
                label: const Text('Try 3D'),
              ),
            ),
        ],
      ),
    );
  }
}

class _MapError extends StatelessWidget {
  const _MapError({
    required this.message,
    required this.onRetry,
    required this.onOpen2d,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpen2d;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, color: MilesColors.ember, size: 30),
            const SizedBox(height: 12),
            const Text('3D map unavailable',
                style: TextStyle(
                    color: MilesColors.cream50,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: MilesColors.taupe, height: 1.4)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton(
                    onPressed: onRetry, child: const Text('Retry 3D')),
                FilledButton(
                    onPressed: onOpen2d, child: const Text('Open 2D map')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
