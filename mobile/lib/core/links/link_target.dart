/// What a URL is, decided without touching the network.
///
/// Everything here is pure and synchronous so a bubble can classify a link
/// while it builds. A reel, a TikTok and a YouTube video look different in the
/// list and open differently, and none of that needs a request — the platform
/// and the id are in the string.
///
/// The network half (title, description, thumbnail) is an upgrade that arrives
/// later from the unfurl function. This layer is what makes the card work
/// without it.
library;

enum LinkProvider { youtube, instagram, tiktok, twitter, spotify, generic }

/// A classified link.
class LinkTarget {
  const LinkTarget({
    required this.raw,
    required this.canonical,
    required this.provider,
    required this.label,
    this.id,
  });

  /// Exactly as it appeared in the message body.
  final String raw;

  /// Tracking parameters removed, ready to be a cache key or handed onward.
  final String canonical;

  final LinkProvider provider;

  /// The platform's own word for this kind of thing — "Reel", "Short",
  /// "Video". Shown on the card before anything has been fetched.
  final String label;

  /// The platform's content id where one is derivable. Null for a shortened
  /// URL that has to be resolved first.
  final String? id;

  /// The site's display name.
  String get site => switch (provider) {
        LinkProvider.youtube => 'YouTube',
        LinkProvider.instagram => 'Instagram',
        LinkProvider.tiktok => 'TikTok',
        LinkProvider.twitter => 'X',
        LinkProvider.spotify => 'Spotify',
        LinkProvider.generic => Uri.tryParse(canonical)?.host ?? '',
      };

  /// A poster image derivable from the id alone, with NO network call.
  ///
  /// Only YouTube publishes one at a predictable path. Everything else needs
  /// the unfurl, which is why the card has to look deliberate without a
  /// picture rather than treating one as the point.
  String? get derivedThumbUrl => provider == LinkProvider.youtube && id != null
      ? 'https://i.ytimg.com/vi/$id/hqdefault.jpg'
      : null;
}

/// Query parameters that identify the SHARER rather than the content.
///
/// `igshid` and `si` are per-share tokens minted when someone taps Share, so
/// leaving them in means two cache keys for one reel — and means the URL handed
/// to a third party identifies the account the share came from. Stripping is a
/// privacy measure first and a deduplication measure second.
const _junkParams = {
  'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content',
  'fbclid', 'igshid', 'igsh', 'si', 'is_from_webapp', 'sender_device',
  'feature', 'ref_src', 'ref_url', '_r', '_t', 'source',
};

final _youtubeId = RegExp(
  r'(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|embed/|live/)|youtu\.be/)([A-Za-z0-9_-]{6,})',
  caseSensitive: false,
);
final _instagram = RegExp(
  r'instagram\.com/(reels?|p|tv)/([A-Za-z0-9_-]+)',
  caseSensitive: false,
);
final _tiktokFull = RegExp(
  r'tiktok\.com/@[\w.-]+/video/(\d{6,})',
  caseSensitive: false,
);
final _tiktokShort =
    RegExp(r'(?:vm|vt)\.tiktok\.com/([A-Za-z0-9]+)', caseSensitive: false);
final _tweet = RegExp(
  r'(?:twitter|x)\.com/[\w]+/status/(\d+)',
  caseSensitive: false,
);
final _spotify = RegExp(
  r'open\.spotify\.com/(track|album|playlist|episode|show)/([A-Za-z0-9]+)',
  caseSensitive: false,
);

/// Remove the parameters that describe who shared rather than what was shared.
String canonicalise(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme) return url.trim();
  final kept = <String, String>{
    for (final e in u.queryParameters.entries)
      if (!_junkParams.contains(e.key.toLowerCase())) e.key: e.value,
  };
  // `music.youtube.com` is deliberately rewritten to the plain host: its embed
  // and its oEmbed both behave differently, and everything downstream would
  // have to special-case a difference that is not real to the user.
  var host = u.host.toLowerCase();
  if (host == 'music.youtube.com') host = 'www.youtube.com';
  // `queryParameters: null` means LEAVE THE QUERY ALONE, not clear it — so
  // stripping every parameter has to go through `query: ''` or the junk
  // survives untouched. Both forms then leave a dangling '?' or '#'.
  final rebuilt = kept.isEmpty
      ? u.replace(host: host, query: '', fragment: '')
      : u.replace(host: host, queryParameters: kept, fragment: '');
  return rebuilt.toString().replaceFirst(RegExp(r'[?#]+$'), '');
}

/// Classify [url]. Never returns null — an unrecognised link is still a link.
LinkTarget classifyLink(String url) {
  final canon = canonicalise(url);

  final yt = _youtubeId.firstMatch(canon);
  if (yt != null) {
    final isShort = canon.contains('/shorts/');
    return LinkTarget(
      raw: url,
      canonical: canon,
      provider: LinkProvider.youtube,
      label: isShort ? 'Short' : 'Video',
      id: yt.group(1),
    );
  }

  final ig = _instagram.firstMatch(canon);
  if (ig != null) {
    final kind = ig.group(1)!.toLowerCase();
    return LinkTarget(
      raw: url,
      canonical: canon,
      provider: LinkProvider.instagram,
      label: kind.startsWith('reel')
          ? 'Reel'
          : kind == 'tv'
              ? 'IGTV'
              : 'Post',
      id: ig.group(2),
    );
  }

  final tt = _tiktokFull.firstMatch(canon);
  if (tt != null) {
    return LinkTarget(
      raw: url,
      canonical: canon,
      provider: LinkProvider.tiktok,
      label: 'Video',
      id: tt.group(1),
    );
  }
  if (_tiktokShort.hasMatch(canon)) {
    // A shortlink carries no content id until something follows the redirect,
    // which is the unfurl's job, not a bubble's.
    return LinkTarget(
      raw: url,
      canonical: canon,
      provider: LinkProvider.tiktok,
      label: 'Video',
    );
  }

  final tw = _tweet.firstMatch(canon);
  if (tw != null) {
    return LinkTarget(
      raw: url,
      canonical: canon,
      provider: LinkProvider.twitter,
      label: 'Post',
      id: tw.group(1),
    );
  }

  final sp = _spotify.firstMatch(canon);
  if (sp != null) {
    return LinkTarget(
      raw: url,
      canonical: canon,
      provider: LinkProvider.spotify,
      label: sp.group(1)!,
      id: sp.group(2),
    );
  }

  return LinkTarget(
    raw: url,
    canonical: canon,
    provider: LinkProvider.generic,
    label: 'Link',
  );
}
