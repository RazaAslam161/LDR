import 'package:flutter/material.dart';
import 'package:miles/core/theme.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Full-screen realistic **3D map** of the partner's location — FREE, no API key:
/// real satellite imagery (Esri) draped over real 3D terrain (AWS elevation) with
/// 3D buildings (OpenStreetMap), tilted with a gentle auto-orbit. Rendered with
/// MapLibre GL JS inside a WebView.
class Map3DScreen extends StatefulWidget {
  const Map3DScreen({
    super.key,
    required this.lat,
    required this.lon,
    required this.name,
  });

  final double lat;
  final double lon;
  final String name;

  @override
  State<Map3DScreen> createState() => _Map3DScreenState();
}

class _Map3DScreenState extends State<Map3DScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(MilesColors.night)
      ..loadHtmlString(_html(widget.lat, widget.lon, widget.name));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        backgroundColor: MilesColors.night,
        title: Text('${widget.name} · 3D',
            style: const TextStyle(color: MilesColors.cream50)),
        iconTheme: const IconThemeData(color: MilesColors.cream50),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }

  static String _esc(String s) =>
      s.replaceAll('\\', '').replaceAll('"', '').replaceAll('\n', ' ');

  static String _html(double lat, double lon, String name) {
    _esc(name); // (name kept for the title bar; marker is unlabeled)
    return '''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<link href="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css" rel="stylesheet" />
<script src="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js"></script>
<style>html,body,#map{height:100%;margin:0;padding:0;background:#0a0a0a;}</style>
</head>
<body>
<div id="map"></div>
<script>
const LAT=$lat, LNG=$lon;
const map = new maplibregl.Map({
  container:'map',
  center:[LNG, LAT],
  zoom:18.4,
  pitch:58,
  bearing:28,
  maxPitch:85,
  attributionControl:false,
  style:{
    version:8,
    sources:{
      sat:{type:'raster', tiles:['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'], tileSize:256, maxzoom:21, attribution:'Esri'},
      terrain:{type:'raster-dem', tiles:['https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png'], encoding:'terrarium', tileSize:256, maxzoom:15},
      osm:{type:'vector', url:'https://tiles.openfreemap.org/planet'}
    },
    layers:[
      {id:'sat', type:'raster', source:'sat'},
      {id:'bld3d', type:'fill-extrusion', source:'osm', 'source-layer':'building', minzoom:14,
        paint:{
          'fill-extrusion-color':'#c9c9d2',
          'fill-extrusion-height':['coalesce',['get','render_height'],['get','height'],6],
          'fill-extrusion-base':['coalesce',['get','render_min_height'],0],
          'fill-extrusion-opacity':0.82
        }}
    ],
    terrain:{source:'terrain', exaggeration:1.4},
    sky:{'sky-color':'#10131f','horizon-color':'#26304a','fog-color':'#0a0a0a','sky-horizon-blend':0.5,'horizon-fog-blend':0.5}
  }
});
map.on('load', ()=>{
  try { map.setTerrain({source:'terrain', exaggeration:1.4}); } catch(e){}
  const el=document.createElement('div');
  el.style.cssText='width:18px;height:18px;border-radius:50%;background:#E08AA0;border:2px solid #fff;box-shadow:0 0 12px #E08AA0;';
  new maplibregl.Marker({element:el}).setLngLat([LNG,LAT]).addTo(map);
  let b=28;
  setInterval(()=>{ b=(b+0.12)%360; map.setBearing(b); }, 60);
});
map.on('error', e=>{ /* keep rendering whatever loaded (sat/terrain) */ });
</script>
</body>
</html>
''';
  }
}
