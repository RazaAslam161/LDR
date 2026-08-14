/// Turns arbitrary pasted text into something Watch Together can act on.
///
/// The screen used to call YoutubePlayer.convertUrlToId, whose five regexes
/// are all anchored `^https:\/\/` and require `v` to be the FIRST query
/// parameter. So a Short, a `youtu.be` link carrying `?si=`, a `/live/` stream,
/// an `m.youtube.com` link, or anything copied with a word in front of it was
/// rejected as "not a YouTube link" — which is most of what a person actually
/// pastes off a phone.
///
/// Everything here is pure and synchronous so it can be tested without a
/// player, a socket, or a network.
library;

import 'package:miles/core/links/link_target.dart';

/// What we can do with a link.
enum WatchKind {
  /// Plays inline in the YouTube iframe player.
  youtube,

  /// A media file we can hand straight to video_player.
  media,

  /// A real video, on a site that will not play inside another app. Opened in
  /// the browser on both phones instead of pretending we can embed it.
  handoff,

  /// Known to be impossible, so say so rather than spinning.
  blocked,
}

/// Which demuxer video_player should be told to use.
enum MediaFormat { hls, dash, ss, other }

class WatchSource {
  const WatchSource({
    required this.kind,
    required this.key,
    this.startAt = Duration.zero,
    this.format,
    this.original,
    this.site,
    this.reason,
  });

  /// youtube: the bare 11-character id. media/handoff: a canonical https URL.
  final String key;
  final WatchKind kind;

  /// A timestamp carried by the link (`?t=90`, `#t=1m30s`). Honoured on open.
  final Duration startAt;
  final MediaFormat? format;
  final Uri? original;

  /// Human name of the host, for the card. 'Vimeo', 'Netflix'.
  final String? site;

  /// Shown to the user verbatim. Never a shrug.
  final String? reason;
}

const _ytHosts = {'youtube.com', 'youtu.be', 'youtube-nocookie.com'};

/// Sites that carry real video but refuse to be embedded. Opened in a browser.
const _handoffSites = <String, String>{
  'vimeo.com': 'Vimeo',
  'dailymotion.com': 'Dailymotion',
  'twitch.tv': 'Twitch',
  'tiktok.com': 'TikTok',
  'instagram.com': 'Instagram',
  'facebook.com': 'Facebook',
  'fb.watch': 'Facebook',
  'x.com': 'X',
  'twitter.com': 'X',
  'reddit.com': 'Reddit',
  'drive.google.com': 'Google Drive',
};

/// DRM services. No player will ever open these, so say it plainly once
/// instead of failing differently every time.
const _drmSites = <String, String>{
  'netflix.com': 'Netflix',
  'primevideo.com': 'Prime Video',
  'amazon.com': 'Prime Video',
  'disneyplus.com': 'Disney+',
  'hotstar.com': 'Disney+ Hotstar',
  'max.com': 'Max',
  'hbomax.com': 'Max',
  'hulu.com': 'Hulu',
  'appletv.com': 'Apple TV+',
};

const _mediaExt = {
  '.mp4', '.m4v', '.mov', '.webm', '.mkv', '.m3u8', '.mpd', '.ts',
  '.mp3', '.m4a', '.aac', '.opus', '.ogg', '.wav', '.flac',
};

final _urlInText = RegExp(
  r'(?:https?://|www\.)[^\s<>"]+',
  caseSensitive: false,
);
final _bareId = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _hostish = RegExp(r'^[\w.-]+\.[a-zA-Z]{2,}(/|$)');

/// Resolve [pasted] without touching the network. Null means it is not a link.
WatchSource? resolveWatchLink(String pasted) {
  final raw = pasted.trim();
  if (raw.isEmpty) return null;

  // People paste "look at this https://… lol". Take the first URL in the text.
  var candidate = _urlInText.stringMatch(raw) ?? '';
  if (candidate.isEmpty) {
    if (_bareId.hasMatch(raw)) {
      return WatchSource(kind: WatchKind.youtube, key: raw);
    }
    if (!_hostish.hasMatch(raw)) return null;
    candidate = raw;
  }

  // Paste damage: HTML-escaped ampersands, and trailing sentence punctuation
  // that is not part of the URL.
  candidate = candidate.replaceAll('&amp;', '&');
  candidate = candidate.replaceAll(RegExp(r'[)\]}.,;]+$'), '');
  if (!candidate.startsWith('http')) candidate = 'https://$candidate';

  // The app's own canonicaliser, so there is one URL parser here and not two
  // that disagree. It already strips si/igshid and rewrites music.youtube.com.
  final uri = Uri.tryParse(canonicalise(candidate));
  if (uri == null || !uri.hasAuthority) return null;

  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www|m)\.'), '');
  final start = _startAt(uri);

  if (_ytHosts.any((h) => host == h || host.endsWith('.$h'))) {
    return _youtube(uri, host, start);
  }

  for (final e in _drmSites.entries) {
    if (host == e.key || host.endsWith('.${e.key}')) {
      return WatchSource(
        kind: WatchKind.blocked,
        key: uri.toString(),
        original: uri,
        site: e.value,
        reason: '${e.value} is DRM-protected, so it can never play inside '
            'another app. Start it on both phones and press play together.',
      );
    }
  }

  for (final e in _handoffSites.entries) {
    if (host == e.key || host.endsWith('.${e.key}')) {
      return WatchSource(
        kind: WatchKind.handoff,
        key: _rewrite(uri).toString(),
        startAt: start,
        original: uri,
        site: e.value,
        reason: "${e.value} won't play inside Miles. Opening it in your "
            "browser — you'll both need to press play.",
      );
    }
  }

  final rewritten = _rewrite(uri);
  final fmt = _formatOf(rewritten);
  if (fmt != null) {
    // http media cannot load: cleartext is denied app-wide, and re-enabling it
    // to play one video would weaken transport security for everything else.
    if (rewritten.scheme == 'http') {
      return WatchSource(
        kind: WatchKind.blocked,
        key: rewritten.toString(),
        original: uri,
        reason: 'This link is unencrypted (http). Try the https version, or '
            'open it in your browser.',
      );
    }
    return WatchSource(
      kind: WatchKind.media,
      key: rewritten.toString(),
      startAt: start,
      format: fmt,
      original: uri,
    );
  }

  // A real link we cannot classify. He pasted it for a reason, so it opens in
  // a browser rather than being called invalid.
  return WatchSource(
    kind: WatchKind.handoff,
    key: rewritten.toString(),
    startAt: start,
    original: uri,
    site: host,
    reason: "Miles can't play this one inline. Opening it in your browser — "
        "you'll both need to press play.",
  );
}

WatchSource? _youtube(Uri uri, String host, Duration start) {
  String? id;
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (host == 'youtu.be') {
    id = segs.isNotEmpty ? segs.first : null;
  } else if (uri.path == '/watch') {
    // By name, never by position: `?list=..&v=..` is a normal share shape and
    // the old regex required v to come first.
    id = uri.queryParameters['v'];
  } else if (segs.length >= 2 &&
      const {'shorts', 'embed', 'live', 'v'}.contains(segs.first)) {
    id = segs[1];
  }

  if (id != null && _bareId.hasMatch(id)) {
    return WatchSource(
      kind: WatchKind.youtube,
      key: id,
      startAt: start,
      original: uri,
      site: 'YouTube',
    );
  }

  // A playlist with no video: the Dart controller exposes no playlist method,
  // so this would load nothing at all.
  if (uri.queryParameters['list'] != null) {
    return WatchSource(
      kind: WatchKind.handoff,
      key: uri.toString(),
      original: uri,
      site: 'YouTube',
      reason: 'Miles plays single videos, not playlists. Opening this in your '
          'browser — or paste one video from it to watch in sync.',
    );
  }
  return null;
}

/// Host-specific string rewrites that turn a share link into a media link.
/// No network: each is a pure transformation of the URL.
Uri _rewrite(Uri uri) {
  final host = uri.host.toLowerCase();
  if (host.endsWith('dropbox.com')) {
    final q = Map<String, String>.from(uri.queryParameters)..['raw'] = '1';
    q.remove('dl');
    return uri.replace(queryParameters: q);
  }
  if (host == 'v.redd.it' && uri.pathSegments.isNotEmpty) {
    return uri.replace(path: '/${uri.pathSegments.first}/DASHPlaylist.mpd');
  }
  return uri;
}

MediaFormat? _formatOf(Uri uri) {
  final path = uri.path.toLowerCase();
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = path.substring(dot);
  if (!_mediaExt.contains(ext)) return null;
  return switch (ext) {
    '.m3u8' => MediaFormat.hls,
    '.mpd' => MediaFormat.dash,
    _ => MediaFormat.other,
  };
}

/// A timestamp on the link. Accepts `90`, `90s`, `1m30s`, `1h2m3s`, `1:30`
/// and `1:02:03`, from `t`, `start`, `time_continue` or the `#t=` fragment.
Duration _startAt(Uri uri) {
  final raw = uri.queryParameters['t'] ??
      uri.queryParameters['start'] ??
      uri.queryParameters['time_continue'] ??
      (uri.fragment.startsWith('t=') ? uri.fragment.substring(2) : null);
  return parseTimestamp(raw);
}

Duration parseTimestamp(String? raw) {
  if (raw == null || raw.isEmpty) return Duration.zero;
  final s = raw.trim().toLowerCase();

  final plain = int.tryParse(s);
  if (plain != null) return Duration(seconds: plain);

  if (s.contains(':')) {
    final parts = s.split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return Duration.zero;
    final n = parts.cast<int>();
    if (n.length == 2) return Duration(minutes: n[0], seconds: n[1]);
    if (n.length == 3) {
      return Duration(hours: n[0], minutes: n[1], seconds: n[2]);
    }
    return Duration.zero;
  }

  final m = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$').firstMatch(s);
  if (m == null || m.group(0)!.isEmpty) return Duration.zero;
  return Duration(
    hours: int.tryParse(m.group(1) ?? '') ?? 0,
    minutes: int.tryParse(m.group(2) ?? '') ?? 0,
    seconds: int.tryParse(m.group(3) ?? '') ?? 0,
  );
}

/// Rebuild a source from the key that travelled on the wire.
///
/// The two backends are told apart by shape: a YouTube id is eleven characters
/// of id alphabet, everything else is a URL. So the partner's phone opens the
/// same kind of player without the protocol having to carry a type tag.
WatchSource? sourceFromKey(String key, {Duration startAt = Duration.zero}) {
  if (_bareId.hasMatch(key)) {
    return WatchSource(
      kind: WatchKind.youtube,
      key: key,
      startAt: startAt,
      site: 'YouTube',
    );
  }
  final s = resolveWatchLink(key);
  if (s == null || startAt == Duration.zero) return s;
  return WatchSource(
    kind: s.kind,
    key: s.key,
    startAt: startAt,
    format: s.format,
    original: s.original,
    site: s.site,
    reason: s.reason,
  );
}
