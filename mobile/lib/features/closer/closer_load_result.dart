import 'package:flutter/foundation.dart';
import 'package:miles/core/data/supabase_repository.dart';

/// A list load that knows what it could not open.
///
/// The Closer repositories used to `catch (_) { continue; }` per row, so a row
/// that failed to parse or decrypt vanished with no trace. An empty vault and
/// a vault whose every row failed to decrypt rendered identically — and to the
/// person looking at it, "empty" reads as "my data is gone".
///
/// That mattered more once encryption came back: until both partners have
/// published a key, a row written by the other device legitimately cannot be
/// opened yet. Silence would have turned a temporary, self-healing state into
/// an apparent data loss.
@immutable
class CloserLoadResult<T> {
  const CloserLoadResult(this.items, {this.unreadable = 0});

  final List<T> items;

  /// Rows that were skipped because they could not be parsed or decrypted.
  final int unreadable;

  bool get hasUnreadable => unreadable > 0;

  /// What to tell the user. Deliberately does not say "corrupt": the usual
  /// cause is a partner who has not opened the updated app yet, which fixes
  /// itself the moment they do.
  String get unreadableMessage {
    // A reinstall regenerates this device's key, so everything written under
    // the old one is permanently unreadable here. Saying "couldn't be opened"
    // would imply it is coming back; it is not.
    if (SupabaseRepository.keyWasReplaced) {
      return unreadable == 1
          ? "1 item was encrypted on your previous install and can't be opened"
          : '$unreadable items were encrypted on your previous install and '
              "can't be opened";
    }
    return unreadable == 1
        ? "1 item couldn't be opened — your partner may need to open Closer"
        : "$unreadable items couldn't be opened — your partner may need to "
            'open Closer';
  }
}
