/// The per-site half of an embedded player, with no Flutter in it.
///
/// A site is drivable only if it publishes a way to say play, pause and seek to
/// a video inside a cross-origin iframe. That is a per-site decision and a
/// per-site string format, and it is the only part of an embedded player worth
/// testing — so it lives here, pure, rather than tangled into a widget.
///
/// Two sites qualify today. YouTube has its own package and is not one of them.
library;

/// One embeddable site.
class EmbedAdapter {
  const EmbedAdapter({
    required this.site,
    required this.playerUrl,
    required this.origin,
    required this.bridge,
    required this.play,
    required this.pause,
    required this.seek,
  });

  /// Human name, for the card.
  final String site;

  /// The iframe URL to load for a source key.
  final Uri Function(String key, Duration startAt) playerUrl;

  /// The origin the shim page is served as. Vimeo requires a real https origin
  /// to accept postMessage; a page loaded from about:blank has origin "null"
  /// and is refused.
  final String origin;

  /// JS installed once, which must call
  /// `window.flutter_inappwebview.callHandler('watch', ...)` with
  /// `{event, time}` as the player reports.
  final String bridge;

  final String play;
  final String pause;

  /// Built per call because the position is an argument.
  final String Function(Duration to) seek;
}

/// Vimeo, through player.js.
///
/// Position comes from the `timeupdate` event, never from `getCurrentTime()`:
/// every player.js method returns a Promise, so polling it across the Flutter
/// bridge would read a value that arrives a frame later than it is asked for.
/// `dnt=1` tells Vimeo not to track the session, which is the most this app can
/// do about a third party seeing that a video was opened.
final _vimeo = EmbedAdapter(
  site: 'Vimeo',
  origin: 'https://player.vimeo.com',
  playerUrl: (key, startAt) => Uri.parse(
    'https://player.vimeo.com/video/$key'
    '?dnt=1&playsinline=1&autoplay=0'
    '${startAt > Duration.zero ? '#t=${startAt.inSeconds}s' : ''}',
  ),
  bridge: '''
var p = new Vimeo.Player(document.querySelector('iframe'));
function post(e, t) {
  window.flutter_inappwebview.callHandler('watch', {event: e, time: t || 0});
}
p.on('loaded', function () { post('ready', 0); });
p.on('timeupdate', function (d) { post('time', d.seconds); });
p.on('play',  function (d) { post('play',  d.seconds); });
p.on('pause', function (d) { post('pause', d.seconds); });
p.on('error', function (d) { post('error', 0); });
window.__w = p;
''',
  play: 'window.__w.play();',
  pause: 'window.__w.pause();',
  seek: (to) => 'window.__w.setCurrentTime(${to.inMilliseconds / 1000});',
);

/// TikTok, through the embed player's postMessage protocol.
///
/// Every message in either direction carries `'x-tiktok-player': true`, which
/// is how the player tells its own traffic from anything else on the page.
/// onStateChange reports 1 for playing and 2 for paused; onCurrentTime carries
/// both the position and the duration.
final _tiktok = EmbedAdapter(
  site: 'TikTok',
  origin: 'https://www.tiktok.com',
  playerUrl: (key, startAt) => Uri.parse(
    'https://www.tiktok.com/player/v1/$key'
    '?music_info=0&description=0&controls=1&autoplay=0'
    '${startAt > Duration.zero ? '&timestamp=${startAt.inSeconds}' : ''}',
  ),
  bridge: '''
var f = document.querySelector('iframe');
function post(e, t) {
  window.flutter_inappwebview.callHandler('watch', {event: e, time: t || 0});
}
function send(type, value) {
  f.contentWindow.postMessage(
    {'x-tiktok-player': true, type: type, value: value}, '*');
}
window.addEventListener('message', function (ev) {
  var d = ev.data;
  if (!d || d['x-tiktok-player'] !== true) return;
  if (d.type === 'onPlayerReady')  post('ready', 0);
  if (d.type === 'onCurrentTime')  post('time', d.value && d.value.currentTime);
  if (d.type === 'onPlayerError')  post('error', 0);
  if (d.type === 'onStateChange') {
    if (d.value === 1) post('play', 0);
    if (d.value === 2) post('pause', 0);
  }
});
window.__w = {send: send};
''',
  play: "window.__w.send('play');",
  pause: "window.__w.send('pause');",
  seek: (to) => "window.__w.send('seekTo', ${to.inMilliseconds / 1000});",
);

/// The adapter for [site], or null if the site cannot be driven.
EmbedAdapter? adapterFor(String site) => switch (site) {
      'Vimeo' => _vimeo,
      'TikTok' => _tiktok,
      _ => null,
    };

/// The page an [EmbedAdapter] is driven from.
///
/// A real https origin, not about:blank: Vimeo's player.js refuses postMessage
/// from an origin of "null", and the whole bridge is postMessage.
String embedHtml(EmbedAdapter a, Uri player) => '''
<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;background:#000;height:100%;overflow:hidden}
iframe{border:0;width:100%;height:100%;display:block}</style>
${a.site == 'Vimeo' ? '<script src="https://player.vimeo.com/api/player.js"></script>' : ''}
</head><body>
<iframe src="$player" allow="autoplay; fullscreen; encrypted-media"
        allowfullscreen></iframe>
<script>${a.bridge}</script>
</body></html>''';
