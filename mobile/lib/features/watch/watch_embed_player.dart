/// A [WatchPlayer] backed by a site's own JS player API, inside a WebView.
///
/// Same contract as the YouTube and media backends, so the sync protocol drives
/// it without knowing it exists. The difference is where position comes from:
/// there is no controller to ask, only events the page pushes across the
/// bridge, so the last reported time is held here and extrapolated between
/// reports. Without that extrapolation the drift correction reads a number up
/// to a quarter of a second stale on every beat and corrects against it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:miles/features/watch/watch_embed.dart';
import 'package:miles/features/watch/watch_player.dart';
import 'package:miles/features/watch/watch_source.dart';
import 'package:miles/features/watch/watch_viewer.dart';

class EmbedWatchPlayer extends ChangeNotifier implements WatchPlayer {
  EmbedWatchPlayer(this.source, this.adapter);

  final WatchSource source;
  final EmbedAdapter adapter;

  InAppWebViewController? _web;
  bool _ready = false;
  bool _playing = false;
  WatchFault? _fault;

  /// The last position the page reported, and when it arrived.
  Duration _reported = Duration.zero;
  DateTime _reportedAt = DateTime.now();

  /// Commands that arrived before the page could honour them. The YouTube
  /// backend learned this the expensive way: a dropped load is a permanent,
  /// unsignalled desync, so nothing is fired and hoped for.
  final _queued = <String>[];

  @override
  String get key => source.key;

  @override
  bool get isReady => _ready;

  @override
  WatchFault? get fault => _fault;

  @override
  bool get isPlaying => _playing;

  /// Extrapolated from the last report while playing, so a caller asking twice
  /// between events gets two different, believable answers.
  @override
  Duration get position {
    if (!_playing) return _reported;
    return _reported + DateTime.now().difference(_reportedAt);
  }

  void _run(String js) {
    final web = _web;
    if (web == null || !_ready) {
      _queued.add(js);
      return;
    }
    web.evaluateJavascript(source: js);
  }

  @override
  void play() => _run(adapter.play);

  @override
  void pause() => _run(adapter.pause);

  @override
  void setVolume(double volume) {
    // An embed is a third party's page in a WebView; there is no volume handle
    // to reach. Ducking silently does nothing here rather than pretending.
  }

  @override
  void seekTo(Duration position) {
    // Held immediately rather than waiting for the page to report back: the
    // protocol may ask for position again before the seek has echoed, and
    // answering with the pre-seek number invites a second correction.
    _reported = position;
    _reportedAt = DateTime.now();
    _run(adapter.seek(position));
  }

  void _onEvent(dynamic raw) {
    final msg = raw is Map ? raw : const <dynamic, dynamic>{};
    final event = msg['event'] as String? ?? '';
    final seconds = (msg['time'] as num?)?.toDouble() ?? 0;

    switch (event) {
      case 'ready':
        _ready = true;
        for (final js in _queued) {
          _web?.evaluateJavascript(source: js);
        }
        _queued.clear();
      case 'time':
        _reported = Duration(milliseconds: (seconds * 1000).round());
        _reportedAt = DateTime.now();
      case 'play':
        _playing = true;
        if (seconds > 0) {
          _reported = Duration(milliseconds: (seconds * 1000).round());
          _reportedAt = DateTime.now();
        }
      case 'pause':
        _playing = false;
        if (seconds > 0) {
          _reported = Duration(milliseconds: (seconds * 1000).round());
        }
      case 'error':
        _fault = '${adapter.site} would not play this one. It may be private, '
            'deleted, or blocked from playing outside ${adapter.site}.';
    }
    notifyListeners();
  }

  @override
  Widget view(BuildContext context) {
    final player = adapter.playerUrl(source.embedId!, source.startAt);
    return AspectRatio(
      // 9:16 for TikTok — it is a vertical format, and forcing 16:9 letterboxes
      // it into a strip with black either side.
      aspectRatio: adapter.site == 'TikTok' ? 9 / 16 : 16 / 9,
      child: ColoredBox(
        color: Colors.black,
        child: InAppWebView(
          initialData: InAppWebViewInitialData(
            data: embedHtml(adapter, player),
            baseUrl: WebUri(adapter.origin),
          ),
          initialSettings: InAppWebViewSettings(
            transparentBackground: true,
            // Left at its default: the app denies cleartext everywhere, and
            // watch_source promises the user exactly that when it refuses an
            // http link.
            mediaPlaybackRequiresUserGesture: false,
            supportZoom: false,
            // The embed players carry their own "open in app" affordances —
            // TikTok's watermark and title are both deep links. Following one
            // ejects the couple to the Play Store mid-video.
            useShouldOverrideUrlLoading: true,
            javaScriptCanOpenWindowsAutomatically: false,
          ),
          shouldOverrideUrlLoading: (_, action) async {
            final url = action.request.url;
            // Only the player itself may navigate. Everything a viewer could
            // tap inside it leads out.
            return staysInViewer(url, origin: Uri.parse(adapter.origin).host) &&
                    url?.host.toLowerCase() ==
                        Uri.parse(adapter.origin).host.toLowerCase()
                ? NavigationActionPolicy.ALLOW
                : NavigationActionPolicy.CANCEL;
          },
          onCreateWindow: (_, __) async => false,
          onWebViewCreated: (c) {
            _web = c;
            c.addJavaScriptHandler(
              handlerName: 'watch',
              callback: (args) {
                _onEvent(args.isEmpty ? null : args.first);
                return null;
              },
            );
          },
          onReceivedError: (_, __, ___) {
            if (_fault != null) return;
            _fault = 'This ${adapter.site} link would not load.';
            notifyListeners();
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _web = null;
    super.dispose();
  }
}
