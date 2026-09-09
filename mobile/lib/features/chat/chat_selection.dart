import 'package:miles/features/chat/chat_repository.dart';

/// One delete of one message — [ChatRepository.deleteForMe] or
/// [ChatRepository.deleteForEveryone], or a fake in a test.
typedef DeleteOne = Future<void> Function(String id);

/// The rules behind selecting messages in bulk.
///
/// This lives outside the chat screen because inside it nothing here could be
/// tested without driving the whole conversation — and a version of it that
/// deleted nothing at all still passed the suite.
class ChatSelection {
  final Set<String> _ids = {};
  bool _busy = false;

  int get length => _ids.length;

  /// Empty means no selection is open. There is no separate flag, so there is
  /// nothing that can disagree with the set itself.
  bool get isActive => _ids.isNotEmpty;

  /// A batch is in flight. A second tap would run every delete again.
  bool get busy => _busy;

  bool contains(String id) => _ids.contains(id);

  /// A message still uploading has no row on the server yet: the delete would
  /// hit nothing and the upload would land it anyway, seconds later. A message
  /// already deleted for everyone has nothing left to delete — the RPC would
  /// update no rows and report success, leaving the placeholder on screen
  /// looking ignored.
  ///
  /// A FAILED send is selectable, and that is a change. It used not to be, on
  /// the same reasoning as an uploading one — but the queue climbs a backoff
  /// ladder now, so `failed` no longer means "not yet": it means the ladder
  /// gave up, and nothing will ever land. A message the user cannot send and
  /// cannot remove is one they are stuck looking at. The chat drains those
  /// through ChatSendQueue.discard rather than the server, which has no row.
  static bool canSelect(Message m) =>
      (m.sendStatus == SendStatus.sent ||
          m.sendStatus == SendStatus.failed) &&
      !m.deletedForEveryone;

  void toggle(Message m) {
    if (!canSelect(m)) return;
    if (!_ids.remove(m.id)) _ids.add(m.id);
  }

  void clear() => _ids.clear();

  /// Replaces the whole selection.
  ///
  /// Drag-select re-derives its entire span on every move rather than toggling
  /// each row it crosses — that is what makes sliding back over a message undo
  /// it instead of selecting it a second time — so it needs to set the set,
  /// not nudge it. [canSelect] is still the gate: an uploading message cannot
  /// be dragged into a selection any more than it can be tapped into one.
  void replaceWith(Iterable<Message> messages) {
    _ids
      ..clear()
      ..addAll(messages.where(canSelect).map((m) => m.id));
  }

  /// Messages can vanish under an open selection — the partner deletes one for
  /// everyone while it is picked. A stale id would inflate the count and make
  /// [allMine] vacuously true.
  void prune(Iterable<String> liveIds) {
    final live = liveIds.toSet();
    _ids.removeWhere((id) => !live.contains(id));
  }

  List<Message> resolve(List<Message> messages) =>
      messages.where((m) => _ids.contains(m.id)).toList();

  /// "Delete for everyone" is sender-only. Offered over a selection holding
  /// the partner's messages, that half of the batch fails server-side.
  bool allMine(List<Message> messages, String? uid) {
    final picked = resolve(messages);
    // every() on an empty list is true, which would offer the destructive
    // option over a selection whose messages are all gone.
    if (picked.isEmpty) return false;
    return picked.every((m) => m.isMine(uid));
  }

  /// Deletes everything selected and returns the ids that failed, which stay
  /// selected so a dropped connection does not cost the user the selection.
  ///
  /// Sequential on purpose: a burst of parallel RPCs from a phone on a bad
  /// connection is how half a selection ends up deleted. One failure does not
  /// abandon the rest — the user asked for all of them gone.
  Future<List<String>> deleteAll(DeleteOne delete) async {
    if (_busy || _ids.isEmpty) return const [];
    _busy = true;
    final failed = <String>[];
    try {
      for (final id in _ids.toList()) {
        try {
          await delete(id);
        } catch (_) {
          failed.add(id);
        }
      }
      _ids
        ..clear()
        ..addAll(failed);
    } finally {
      _busy = false;
    }
    return failed;
  }
}
