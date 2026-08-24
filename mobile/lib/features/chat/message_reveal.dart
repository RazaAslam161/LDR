/// Finding a row that is not on screen, in a list that cannot be told to go to
/// one.
///
/// `ListView.builder` has no scroll-to-index, and `Scrollable.ensureVisible`
/// only works on an element that is currently built — which a message eighty
/// rows back is not. Replacing the list with `scrollable_positioned_list` was
/// the other option and was rejected: it means re-proving realtime, albums,
/// swipe-to-reply and the new-message chip on the app's most important screen.
///
/// The first attempt here bisected the scroll offset, asking the list which
/// rows its itemBuilder had just built and narrowing from that. It does not
/// work, and the reason is worth writing down: a sliver list lays out
/// SEQUENTIALLY, so jumping from the bottom of a long conversation to the
/// middle builds every row in between — one probe reported building rows 6
/// through 187 — and then discards the ones far from the viewport. "Which rows
/// did you build" is not "which rows are on screen", so the search declared
/// victory on a row that had already been thrown away.
///
/// That failure is also the solution. Because layout is sequential, one jump
/// past the target measures every row before it, and a row's offset is then
/// just the sum of the heights in front of it. This holds the measurements and
/// does that sum. It is exact for every row that has been laid out at least
/// once, and degrades to the running mean for rows nobody has reached yet —
/// which is what makes the first jump land close enough to measure the rest.
///
/// Pure on purpose: no Flutter, no ScrollController, no frames. The screen this
/// serves is over three thousand lines and no widget test drives it, so the
/// part with the arithmetic in it is kept somewhere a test can reach.
class RowOffsets {
  /// Keyed by row identity, never by index. Indices shift the moment a message
  /// arrives — a realtime insert lands at the newest end and renumbers
  /// everything older — and a height map keyed by a number that moves is a map
  /// that quietly starts lying.
  final Map<String, double> _heights = {};

  /// A row height to assume before anything has been measured. Only ever used
  /// on a conversation opened and jumped through in the same breath.
  static const double coldFallback = 72;

  int get measuredCount => _heights.length;

  void record(String rowId, double height) {
    if (height > 0) _heights[rowId] = height;
  }

  double? heightOf(String rowId) => _heights[rowId];

  /// The average of what has actually been measured, for rows that have not.
  double get meanHeight {
    if (_heights.isEmpty) return coldFallback;
    var total = 0.0;
    for (final h in _heights.values) {
      total += h;
    }
    return total / _heights.length;
  }

  /// How far down the list row [index] begins.
  ///
  /// Under `reverse: true` the newest row is index 0 at offset 0 and the
  /// conversation runs backwards from there, so this is simply everything in
  /// front of the target added up.
  double offsetOf(List<String> rowIds, int index) {
    final mean = meanHeight;
    var offset = 0.0;
    final upto = index < rowIds.length ? index : rowIds.length;
    for (var i = 0; i < upto; i++) {
      offset += _heights[rowIds[i]] ?? mean;
    }
    return offset;
  }

  /// The offset that puts row [index] in the MIDDLE of a [viewport]-tall
  /// window, clamped to what the list can actually scroll to.
  ///
  /// Centred rather than flush to an edge because the point of the jump is to
  /// read the message with the conversation around it — a row pinned to the
  /// top edge looks like the end of the history.
  double centredOffsetFor(
    List<String> rowIds,
    int index, {
    required double viewport,
    required double maxExtent,
  }) {
    final top = offsetOf(rowIds, index);
    final own = index < rowIds.length
        ? (_heights[rowIds[index]] ?? meanHeight)
        : meanHeight;
    final centred = top - (viewport - own) / 2;
    if (centred < 0) return 0;
    return centred > maxExtent ? maxExtent : centred;
  }

  /// Whether every row in front of [index] has been measured, so
  /// [centredOffsetFor] is exact rather than an estimate.
  ///
  /// The caller uses this to know whether another pass can improve on the last
  /// one, instead of jumping a fixed number of times and hoping.
  bool isExactFor(List<String> rowIds, int index) {
    final upto = index < rowIds.length ? index : rowIds.length;
    for (var i = 0; i < upto; i++) {
      if (!_heights.containsKey(rowIds[i])) return false;
    }
    return true;
  }

  /// Forget a row that is no longer in the conversation, so a deleted message
  /// does not keep a height alive for the life of the screen.
  void forgetAllExcept(Set<String> keep) {
    _heights.removeWhere((id, _) => !keep.contains(id));
  }
}
