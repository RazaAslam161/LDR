import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/features/closer/memory_threads/memory_photo_repository.dart';
import 'package:miles/features/closer/memory_threads/memory_thread_repository.dart';

/// Moves a pre-007000 inline photograph out of its database row and into
/// `memory_photos`, using the device that can already decrypt it.
///
/// A server-side backfill is impossible in principle, not merely inconvenient:
/// the key exists on exactly two handsets and `exportPrivateSeed` is the only
/// way it ever leaves one. So `photo_cipher`/`photo_nonce` stay in the schema
/// permanently and this is the only migration path there is.
///
/// Shaped like `ThumbBackfill`: one at a time, ids remembered so a failure is
/// not retried on every rebuild, and the work is only ever done for a row the
/// user is already looking at.
class MemoryHeal {
  MemoryHeal._();

  /// A decrypt, a 12-megapixel decode, two resizes, three encrypts and three
  /// uploads. Running two of those concurrently on a 2-core handset that is
  /// also trying to scroll is how a background optimisation becomes a stutter.
  static bool _busy = false;

  /// Attempted this run, successfully or not. The two ways this fails are a
  /// decode the platform cannot do and an upload the network will not take, and
  /// neither improves by being retried forty milliseconds later on the next
  /// scroll frame.
  static final Set<String> _seen = <String>{};

  static Timer? _dwell;

  /// How long the list must be still before any of this starts.
  static const _dwellFor = Duration(seconds: 2);

  @visibleForTesting
  static Set<String> get debugSeen => _seen;

  @visibleForTesting
  static void resetForTest() {
    _busy = false;
    _seen.clear();
    _dwell?.cancel();
    _dwell = null;
  }

  /// Call on every list emission. Heals ONE row once the list has been quiet.
  ///
  /// Debounced rather than driven per frame: a realtime tick, a scroll and a
  /// rebuild all land here, and healing during any of them competes with the
  /// thing the user is actually doing.
  static void onListSettled({
    required List<MemoryThread> threads,
    required String coupleId,
    required String me,
  }) {
    _dwell?.cancel();
    _dwell = Timer(_dwellFor, () {
      final candidate = threads.firstWhereOrNull(
        (t) => t.photoNonce != null && t.coverPath == null && !_seen.contains(t.id),
      );
      if (candidate != null) {
        unawaited(heal(thread: candidate, coupleId: coupleId, me: me));
      }
    });
  }

  /// Re-encrypts one memory's inline photograph as three storage objects.
  ///
  /// Returns true only when the row was migrated AND the inline columns
  /// cleared.
  static Future<bool> heal({
    required MemoryThread thread,
    required String coupleId,
    required String me,
  }) async {
    if (_busy || _seen.contains(thread.id)) return false;

    // NON-NEGOTIABLE, and the reason is the opposite of the obvious one.
    //
    // `decryptBytes` short-circuits on the legacy signature — an all-zero nonce
    // and MAC — and returns the plaintext WITHOUT needing a key at all. One
    // production row is in exactly that state. So in plaintext mode this whole
    // function would succeed on that row: decrypt (trivially), re-encrypt (to
    // nothing, because there is no key), upload a cleartext JPEG behind a
    // shareable signed URL, and then null the original column — erasing the
    // evidence of the very thing it exists to fix.
    //
    // Heal must be a remediation, never a propagation mechanism.
    if (await CryptoCore.exportSharedKeyBytes() == null) return false;

    _busy = true;
    _seen.add(thread.id);
    try {
      final bytes = await decryptPhoto(thread);
      if (bytes == null || bytes.isEmpty) return false;

      // Upload FIRST. memory_clear_inline_photo refuses while no replacement
      // row exists, so even a crash between these two leaves the inline column
      // as the source of truth and the next dwell tries again.
      await MemoryPhotoRepository.upload(
        coupleId: coupleId,
        memoryId: thread.id,
        addedBy: me,
        position: 0,
        original: bytes,
      );

      await SupabaseService.client.rpc<void>(
        'memory_clear_inline_photo',
        params: {'p_id': thread.id},
      );
      return true;
    } catch (e) {
      // Silent by design: the row is untouched, the picture still renders from
      // the inline column, and there is nothing a user could do about it.
      debugPrint('[memory-heal] ${e.runtimeType}');
      return false;
    } finally {
      _busy = false;
    }
  }
}

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
