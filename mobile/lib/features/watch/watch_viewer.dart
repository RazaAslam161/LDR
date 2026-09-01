/// The link, opened inside Miles instead of in Chrome.
///
/// Not a player and it does not pretend to be one: nothing here reports a
/// position, so nothing claims the two of you are at the same moment. What it
/// buys is the thing being thrown into a browser destroys — you stay in the
/// room, with chat, presence and each other, on a link the app cannot drive.
///
/// It is also a disguise fix. link_open.dart already makes this argument:
/// handing a link to the system browser "puts Instagram in the recent-apps list
/// next to a news reader", and the old Watch Together handoff did exactly that
/// every time, with no prompt.
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/watch/watch_source.dart';
import 'package:url_launcher/url_launcher.dart';

/// Whether the viewer may follow [url] while showing content from [origin].
///
/// Every one of these sites would rather you were in its app, and they all ask
/// the same way: touch the player controls, the scrubber, or fullscreen on
/// x.com and the page fires an `intent://` or a play.google.com redirect. A
/// WebView with no opinion follows it, Android hands off to the Play Store, and
/// the evening is over — which is precisely the ejection this viewer exists to
/// stop, arriving through the back door.
///
/// Allows ordinary browsing within the page; refuses only the ways out.
bool staysInViewer(Uri? url, {String? origin}) {
  if (url == null) return false;

  // intent://, market://, twitter://, tiktok://, fb://, vnd.youtube:// — an
  // app handoff wearing whatever scheme that app registered.
  final scheme = url.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;

  // The https spelling of the same thing. Allowed only if the store IS what
  // the user pasted, which is a strange thing to watch together but not ours
  // to refuse.
  const stores = {'play.google.com', 'apps.apple.com', 'itunes.apple.com'};
  final host = url.host.toLowerCase();
  if (stores.contains(host) && host != origin?.toLowerCase()) return false;

  return true;
}

class WatchViewer extends StatefulWidget {
  const WatchViewer({required this.source, super.key});

  final WatchSource source;

  @override
  State<WatchViewer> createState() => _WatchViewerState();
}

class _WatchViewerState extends State<WatchViewer> {
  double _progress = 0;
  String? _error;

  /// The host the link came from, so a store link is only refused when it is
  /// somewhere the page is trying to send us rather than where we started.
  String? get _origin => Uri.tryParse(widget.source.key)?.host;

  /// A sentence instead of a Chromium error constant.
  ///
  /// ERR_UNKNOWN_URL_SCHEME is the one people actually hit: it means the page
  /// asked Android to open an app, which is the thing this viewer refuses, and
  /// "net::ERR_UNKNOWN_URL_SCHEME" tells the reader nothing about that.
  String _readable(String description) {
    final site = widget.source.site ?? 'This site';
    if (description.contains('UNKNOWN_URL_SCHEME')) {
      return '$site wants to open its own app for this. Miles kept you here '
          'instead — but this part of the page needs the app.';
    }
    return 'This page would not load.\n$description';
  }

  /// Told, not swallowed. Tapping fullscreen and having nothing happen reads as
  /// broken; one line explains it and points at the way out that still works.
  /// When the last refusal was announced.
  ///
  /// These pages fire an app handoff on EVERY touch of the player — unmute,
  /// the scrubber, fullscreen — so an unthrottled message meant a snackbar per
  /// tap, which is what makes the controls feel dead and makes "open in
  /// browser" look like the only thing that works. Say it once a minute.
  DateTime? _saidAt;

  void _refused() {
    if (!mounted) return;
    final now = DateTime.now();
    if (_saidAt != null && now.difference(_saidAt!) < const Duration(minutes: 1)) {
      return;
    }
    _saidAt = now;
    final site = widget.source.site ?? 'This site';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$site tried to open its own app. Staying here.'),
        action: SnackBarAction(
          label: 'Open in browser',
          onPressed: () => launchUrl(
            widget.source.original ?? Uri.parse(widget.source.key),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Not mainAxisSize.min: this Column holds an Expanded, and asking a column
    // to be as short as possible while a child demands all of it is what
    // squeezed the bar above it down to a sliver.
    return Column(
      children: [
        if (_progress < 1 && _error == null)
          LinearProgressIndicator(
            value: _progress == 0 ? null : _progress,
            backgroundColor: MilesColors.surface2,
            color: MilesColors.ember,
            minHeight: 2,
          ),
        Expanded(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: MilesColors.taupe,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 16),
                        // A dead end with no way out was the whole complaint
                        // about the old handoff card.
                        TextButton(
                          // The link the user PASTED, not the rewritten one.
                          // A cobrowse key can be an embed URL, and handing
                          // someone platform.twitter.com/embed/Tweet.html in a
                          // browser shows a bare widget with no way back to the
                          // conversation it came from.
                          onPressed: () => launchUrl(
                            widget.source.original ??
                                Uri.parse(widget.source.key),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: const Text('Open in browser'),
                        ),
                      ],
                    ),
                  ),
                )
              : InAppWebView(
                  initialUrlRequest:
                      URLRequest(url: WebUri(widget.source.key)),
                  initialSettings: InAppWebViewSettings(
                    mediaPlaybackRequiresUserGesture: false,
                    useShouldOverrideUrlLoading: true,
                  ),
                  shouldOverrideUrlLoading: (_, action) async {
                    if (staysInViewer(action.request.url, origin: _origin)) {
                      return NavigationActionPolicy.ALLOW;
                    }
                    _refused();
                    return NavigationActionPolicy.CANCEL;
                  },
                  // target=_blank and window.open take the same route out.
                  onCreateWindow: (_, __) async {
                    _refused();
                    return false;
                  },
                  onProgressChanged: (_, p) =>
                      setState(() => _progress = p / 100),
                  onReceivedError: (_, request, err) {
                    // Main frame only. Every one of these pages loads dozens of
                    // subresources and fires an app deep link the moment you
                    // touch the player, and treating any of that as fatal
                    // replaced a video that was playing perfectly well with a
                    // black ERR_UNKNOWN_URL_SCHEME card.
                    if (request.isForMainFrame != true) return;
                    setState(() => _error = _readable(err.description));
                  },
                ),
        ),
      ],
    );
  }
}
