/// Finding links inside a message body, for display.
///
/// There are deliberately TWO patterns in this app and they are not
/// interchangeable:
///
/// - [SharedMediaRepository.firstUrl] holds `https?://\S*` and is the twin of
///   the `media_class` expression in 20260601005500. That one decides which
///   rows the Links shelf can ever see, so its spelling is fixed by the SQL and
///   a body of bare `http://` has to keep matching it — there is a test whose
///   corpus contains exactly that, with a comment saying why.
/// - [LinkScan.spans] below is a DISPLAY pattern. It decides what to underline
///   and where to stop, so it is allowed to be stricter: trailing punctuation
///   and closing brackets belong to the sentence, not the URL.
///
/// Collapsing them into one pattern is the obvious tidy-up and it breaks the
/// shelf. They have two jobs.
library;

/// One linkified run inside a body.
class LinkSpan {
  const LinkSpan(this.start, this.end, this.url);

  /// Indices into the original body, so the text either side renders normally.
  final int start;
  final int end;

  /// Always carries a scheme, even when the text did not — a bare `www.x.com`
  /// is displayed as typed and opened as `https://www.x.com`.
  final String url;
}

class LinkScan {
  LinkScan._();

  /// Display-time detection. Schemed URLs, plus bare `www.`.
  static final _pattern = RegExp(
    r'(?:https?://|www\.)[^\s<>"' r"'" r']+',
    caseSensitive: false,
  );

  /// Characters that end a sentence rather than a URL.
  static const _trailing = '.,;:!?)]}\'"»”’';

  /// Every link in [body], in order. Empty when there are none.
  ///
  /// Trailing punctuation is trimmed, and a closing bracket is only kept when
  /// the URL opened one — `(see https://x.com/a)` should not link the paren,
  /// but `https://en.wikipedia.org/wiki/A_(b)` should keep it.
  static List<LinkSpan> spans(String? body) {
    if (body == null || body.isEmpty) return const [];
    final out = <LinkSpan>[];
    for (final m in _pattern.allMatches(body)) {
      var text = m.group(0)!;
      var end = m.end;
      while (text.isNotEmpty && _trailing.contains(text[text.length - 1])) {
        final last = text[text.length - 1];
        if ((last == ')' && _balanced(text, '(', ')')) ||
            (last == ']' && _balanced(text, '[', ']'))) {
          break;
        }
        text = text.substring(0, text.length - 1);
        end--;
      }
      if (text.length < 4) continue;
      final url = text.toLowerCase().startsWith('www.') ? 'https://$text' : text;
      out.add(LinkSpan(m.start, end, url));
    }
    return out;
  }

  /// True when [s] has as many openers as closers, i.e. the final closer is
  /// part of the URL rather than the sentence around it.
  static bool _balanced(String s, String open, String close) {
    var depth = 0;
    for (final c in s.split('')) {
      if (c == open) depth++;
      if (c == close) depth--;
    }
    return depth == 0;
  }

  /// The first link in [body], for the card. Null when there is none.
  static String? firstUrl(String? body) {
    final s = spans(body);
    return s.isEmpty ? null : s.first.url;
  }
}
