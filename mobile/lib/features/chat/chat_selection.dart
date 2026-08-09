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
  static bool canSelect(Message m) =>
      m.sendStatus == SendStatus.sent && !m.deletedForEveryone;

  void toggle(Message m) {
    if (!canSelect(m)) return;
    if (!_ids.remove(m.id)) _ids.add(m.id);
  }

  void clear() => _ids.clear();

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
