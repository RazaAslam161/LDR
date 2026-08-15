import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// A single news item parsed from a public RSS feed.
class RssArticle {
  const RssArticle({
    required this.title,
    required this.source,
    required this.url,
    required this.timeAgo,
    this.imageUrl,
    this.pubDate,
  });

  final String title;
  final String source; // e.g. "BBC News"
  final String url;
  final String? imageUrl;
  final DateTime? pubDate;
  final String timeAgo; // "2h ago", "Yesterday", etc.
}

/// Fetches and parses real headlines from public RSS endpoints — no API key,
/// no account. Used purely to make the cover "News" screen look genuine.
class RssService {
  RssService._();

  // Public RSS feeds — a mix of sources for realism.
  static const List<(String, String)> _feeds = [
    ('BBC News', 'https://feeds.bbci.co.uk/news/rss.xml'),
    ('Al Jazeera', 'https://www.aljazeera.com/xml/rss/all.xml'),
    ('NPR', 'https://feeds.npr.org/1001/rss.xml'),
  ];

  /// Last successful fetch, kept STATIC so it survives the news screen being
  /// destroyed/recreated each time the app backgrounds — so re-showing the
  /// cover never flashes a blank loading list.
  static List<RssArticle> cached = const [];
  static DateTime? cachedAt;

  static Future<List<RssArticle>> fetchArticles() async {
    final articles = <RssArticle>[];
    for (final (source, url) in _feeds) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': 'Mozilla/5.0'},
        ).timeout(const Duration(seconds: 6));
        if (response.statusCode == 200) {
          articles.addAll(_parse(response.body, source));
        }
      } catch (_) {
        // One feed failing should not kill the others.
      }
    }
    // Newest first.
    articles.sort((a, b) =>
        (b.pubDate ?? DateTime(0)).compareTo(a.pubDate ?? DateTime(0)),);
    final result = articles.take(30).toList();
    if (result.isNotEmpty) {
      cached = result;
      cachedAt = DateTime.now();
    }
    return result;
  }

  static List<RssArticle> _parse(String xml, String source) {
    try {
      final doc = XmlDocument.parse(xml);
      final out = <RssArticle>[];
      for (final item in doc.findAllElements('item')) {
        final title = _text(item, 'title');
        final link = _text(item, 'link');
        if (title == null || title.isEmpty || link == null || link.isEmpty) {
          continue;
        }
        final pub = _parseRfc822(_text(item, 'pubDate'));
        out.add(RssArticle(
          title: _clean(title),
          source: source,
          url: link.trim(),
          imageUrl: _image(item),
          pubDate: pub,
          timeAgo: _timeAgo(pub),
        ),);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static String? _text(XmlElement item, String name) {
    final els = item.findElements(name);
    if (els.isEmpty) return null;
    return els.first.innerText.trim();
  }

  // Strip any stray HTML tags that slipped through CDATA.
  static String _clean(String s) =>
      s.replaceAll(RegExp('<[^>]*>'), '').trim();

  // <media:content url> / <media:thumbnail url> / <enclosure url type="image/*">.
  static String? _image(XmlElement item) {
    for (final name in const ['media:content', 'media:thumbnail']) {
      for (final el in item.findElements(name)) {
        final u = el.getAttribute('url');
        if (u != null && u.isNotEmpty) return u;
      }
    }
    for (final el in item.findElements('enclosure')) {
      final type = el.getAttribute('type') ?? '';
      final u = el.getAttribute('url');
      if (u != null && u.isNotEmpty && (type.isEmpty || type.startsWith('image'))) {
        return u;
      }
    }
    return null;
  }

  static const _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  static const _namedZones = {
    'GMT': 0, 'UTC': 0, 'UT': 0, 'Z': 0,
    'EST': -300, 'EDT': -240, 'CST': -360, 'CDT': -300,
    'MST': -420, 'MDT': -360, 'PST': -480, 'PDT': -420,
  };

  /// Parses RFC-2822 dates like "Mon, 27 Jun 2026 14:30:00 GMT" / "+0000".
  static DateTime? _parseRfc822(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      var str = raw.trim();
      final comma = str.indexOf(',');
      if (comma != -1 && comma <= 4) str = str.substring(comma + 1).trim();
      final parts = str.split(RegExp(r'\s+'));
      if (parts.length < 5) return null;
      final day = int.parse(parts[0]);
      final month = _months[parts[1]];
      final year = int.parse(parts[2]);
      if (month == null) return null;
      final time = parts[3].split(':');
      final hour = int.parse(time[0]);
      final minute = int.parse(time[1]);
      final second = time.length > 2 ? int.parse(time[2]) : 0;

      var offsetMinutes = 0;
      final tz = parts[4];
      if (tz.startsWith('+') || tz.startsWith('-')) {
        final sign = tz.startsWith('-') ? -1 : 1;
        final digits = tz.substring(1).padRight(4, '0');
        offsetMinutes = sign *
            (int.parse(digits.substring(0, 2)) * 60 +
                int.parse(digits.substring(2, 4)));
      } else {
        offsetMinutes = _namedZones[tz] ?? 0;
      }

      return DateTime.utc(year, month, day, hour, minute, second)
          .subtract(Duration(minutes: offsetMinutes))
          .toLocal();
    } catch (_) {
      return null;
    }
  }

  static String _timeAgo(DateTime? date) {
    if (date == null) return '';
    final diff = DateTime.now().difference(date);
    if (diff.isNegative) return 'now';
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays}d ago';
  }
}
