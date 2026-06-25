import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:miles/core/config.dart';
import 'package:miles/core/theme.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Full-screen Google **photorealistic 3D** map of the partner's location,
/// rendered via the Maps `Map3DElement` web component inside a WebView.
/// Needs GOOGLE_MAPS_3D_KEY in .env (Map Tiles API + Maps JavaScript API + billing).
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
  WebViewController? _controller;
  bool _noKey = false;

  @override
  void initState() {
    super.initState();
    final key = (dotenv.maybeGet(MilesConfig.mapsApiKeyKey) ?? '').trim();
    if (key.isEmpty) {
      _noKey = true;
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(MilesColors.night)
      ..loadHtmlString(_html(key, widget.lat, widget.lon, widget.name));
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
      body: _noKey
          ? _NoKeyMessage()
          : _controller == null
              ? const SizedBox.shrink()
              : WebViewWidget(controller: _controller!),
    );
  }

  static String _esc(String s) =>
      s.replaceAll('\\', '').replaceAll('"', '').replaceAll('\n', ' ');

  static String _html(String key, double lat, double lon, String name) {
    final n = _esc(name);
    return '''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
  html,body{height:100%;margin:0;background:#0a0a0a;}
  gmp-map-3d{height:100%;width:100%;display:block;}
  #err{color:#eee;font-family:sans-serif;padding:22px;font-size:15px;line-height:1.5;}
</style>
</head>
<body>
<gmp-map-3d id="map" mode="hybrid"></gmp-map-3d>
<div id="err"></div>
<script>
(g=>{var h,a,k,p="The Google Maps JavaScript API",c="google",l="importLibrary",q="__ib__",m=document,b=window;b=b[c]||(b[c]={});var d=b.maps||(b.maps={}),r=new Set,e=new URLSearchParams,u=()=>h||(h=new Promise(async(f,n)=>{await(a=m.createElement("script"));e.set("libraries",[...r]+"");for(k in g)e.set(k.replace(/[A-Z]/g,t=>"_"+t[0].toLowerCase()),g[k]);e.set("callback",c+".maps."+q);a.src=`https://maps.\${c}apis.com/maps/api/js?`+e;d[q]=f;a.onerror=()=>h=n(Error(p+" could not load."));a.nonce=m.querySelector("script[nonce]")?.nonce||"";m.head.append(a)}));d[l]?console.warn(p+" only loads once. Ignoring:",g):d[l]=(f,...n)=>r.add(f)&&u().then(()=>d[l](f,...n))})({key:"$key",v:"alpha"});

async function init(){
  try{
    const lib = await google.maps.importLibrary("maps3d");
    const map = document.getElementById('map');
    map.center = {lat: $lat, lng: $lon, altitude: 0};
    map.range = 600;
    map.tilt = 67;
    map.heading = 30;
    try {
      const marker = new lib.Marker3DElement({
        position: {lat: $lat, lng: $lon, altitude: 45},
        label: "$n",
        extruded: true
      });
      map.append(marker);
    } catch(_) {}
    // Gentle auto-orbit so the surroundings read as 3D.
    let hdg = 30;
    setInterval(()=>{ hdg=(hdg+0.15)%360; map.heading=hdg; }, 60);
  }catch(e){
    document.getElementById('map').style.display='none';
    document.getElementById('err').innerText =
      'Could not load 3D map: ' + (e && e.message ? e.message : e) +
      '. Make sure the key has Map Tiles API + Maps JavaScript API enabled and billing on, with no HTTP-referrer restriction.';
  }
}
init();
</script>
</body>
</html>
''';
  }
}

class _NoKeyMessage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.threed_rotation, color: MilesColors.gilt, size: 48),
            SizedBox(height: 16),
            Text('3D map needs a Google Maps key',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: MilesColors.cream50,
                    fontSize: 17,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 10),
            Text(
              'Add a Google Maps Platform API key (Map Tiles API + Maps '
              'JavaScript API, billing on) to mobile/.env as GOOGLE_MAPS_3D_KEY, '
              'then rebuild.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: MilesColors.taupe, fontSize: 13, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}
