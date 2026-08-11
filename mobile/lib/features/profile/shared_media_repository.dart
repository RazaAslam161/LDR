import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/utils/json_utils.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// The three shelves on the partner's profile.
///
/// The names are exactly the values Postgres stores in `messages.media_class`,
/// so choosing a shelf is `.eq()` against an indexed column rather than
/// anything this client has to classify.
enum SharedMediaKind {
  media('Media', 'No photos or videos yet.'),
  file('Documents', 'No documents yet.'),
  link('Links', 'No links yet.');

  const SharedMediaKind(this.tabLabel, this.emptyText);

  /// Carried here rather than in a parallel list beside the TabBar: the tabs
  /// and the shelves behind them are built from this enum, so reordering it
  /// cannot leave "Documents" drawing the photo grid.
  final String tabLabel;
  final String emptyText;
}

/// Everything the two of them have shared, read a page at a time.
///
/// Never "all the media". A conversation is unbounded and a grid is not: asking
/// for every image row so a 3-column grid can be drawn is fine at 300 messages
/// and is a minute of downloading at 40,000. Each call takes [pageSize] rows
/// older than a cursor on `seq` — the same server-assigned order the chat pages
/// on, and the only one that is stable when two devices send at once — so the
/// work per page is constant however long the couple have been talking.
class SharedMediaRepository {
  SharedMediaRepository._();

  /// Two full rows of the grid. Big enough that the first screen is filled
  /// without a second round trip, small enough that the signing call that
  /// follows stays one request.
  static const pageSize = 30;

  /// One page, newest first. [beforeSeq] is the `seq` of the last row of the
  /// previous page; null asks for the newest.
  ///
  /// Returning fewer than [pageSize] rows is the end of the shelf — the caller
  /// stops rather than asking again forever.
  static Future<List<Message>> page(
    String coupleId,
    SharedMediaKind kind, {
    int? beforeSeq,
  }) async {
    var q = SupabaseService.client
        .from('messages')
        .select()
        .eq('couple_id', coupleId)
        .eq('media_class', kind.name)
        .eq('deleted_for_everyone', false);

    // "Delete for me" took it out of the conversation. A grid that shows it
    // anyway is the message coming back through a side door.
    final uid = SupabaseService.currentUserId;
    if (uid != null) q = q.not('deleted_by', 'cs', [uid]);

    if (beforeSeq != null) q = q.lt('seq', beforeSeq);

    final res = await q.order('seq', ascending: false).limit(pageSize);
    final out = <Message>[];
    for (final row in res) {
      try {
        out.add(Message.fromJson(JsonUtils.asMap(row)));
      } catch (_) {
        // Skip a malformed row rather than emptying the whole shelf.
      }
    }
    // One signing request for the page, not one per tile. Thirty tiles each
    // signing on their own is thirty round trips before the grid can paint.
    await ChatRepository.warmMedia(out);
    return out;
  }

  /// The first URL in a message body, or null.
  ///
  /// This regex and the `media_class` expression in
  /// 20260601005500_shared_media_index.sql are two spellings of one test and
  /// have to stay that way: the column decides which rows the Links shelf can
  /// ever see, and this decides what each of them renders as. Disagreement in
  /// one direction hides a link, in the other it draws a blank row.
  ///
  /// `\S*` and not `\S+` for exactly that reason — a body of bare "http://"
  /// satisfies the SQL and would satisfy nothing here.
  static final _url = RegExp(r'https?://\S*', caseSensitive: false);

  static String? firstUrl(String? body) =>
      body == null ? null : _url.firstMatch(body)?.group(0);
}
