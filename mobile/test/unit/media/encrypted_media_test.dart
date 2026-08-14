import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/media/media_decode_queue.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/memory_threads/memory_heal.dart';
import 'package:miles/features/closer/memory_threads/memory_photo_repository.dart';
import 'package:miles/features/closer/memory_threads/memory_thread_repository.dart';

/// The invariants that make encrypted media fast, and the guards that keep it
/// encrypted. Both rot silently: nothing about a duplicated decode or a
/// cleartext upload shows up as an error, which is exactly why they are pinned
/// here rather than left to review.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('provider identity — the reason the cache hands out one instance', () {
    final bytes = Uint8List.fromList(List.generate(64, (i) => i));

    test('two providers over the SAME instance are equal', () {
      // MemoryImage.obtainKey returns `this` and MemoryImage.== compares its
      // bytes field by reference. One instance is therefore one ImageCache
      // entry and one decode, however many surfaces paint it.
      expect(MemoryImage(bytes) == MemoryImage(bytes), isTrue);
    });

    test('a COPY of the same bytes is a different provider', () {
      // This is the whole argument for EncryptedMediaCache returning the
      // identical Uint8List rather than a defensive copy. A copy here is not a
      // small waste — it is a second full decode of the same photograph while
      // the first is still resident.
      final copy = Uint8List.fromList(bytes);
      expect(copy, equals(bytes)); // same CONTENT
      expect(MemoryImage(bytes) == MemoryImage(copy), isFalse); // different KEY
    });

    test('the tile is unbounded and the cover is bounded, so they never share',
        () {
      final memory = MemoryImage(bytes);
      // Typed as ImageProvider on purpose: this is exactly how the cache hands
      // them out, and comparing the concrete types is what the analyzer
      // (correctly) calls an unrelated-type equality check.
      final ImageProvider tile = memory;
      final ImageProvider cover = ResizeImage(memory, width: 864);
      expect(tile == cover, isFalse);
      // Two covers computed at one memoized width DO share.
      expect(ResizeImage(memory, width: 864) == cover, isTrue);
      // A width computed per-card instead of once per screen would not.
      expect(ResizeImage(memory, width: 863) == cover, isFalse);
    });

    test('height is never part of a key we build', () {
      // Passing both dimensions makes the key depend on both, so a square grid
      // tile and a width-only underlay miss each other even when the width
      // agrees. Asserted as a fact about ResizeImage so the rule has teeth.
      final memory = MemoryImage(bytes);
      expect(
        ResizeImage(memory, width: 400) ==
            ResizeImage(memory, width: 400, height: 400),
        isFalse,
      );
    });
  });

  group('key epoch', () {
    test('clearing the key bumps the epoch', () {
      final before = CryptoCore.keyEpoch.value;
      CryptoCore.clearCache();
      expect(CryptoCore.keyEpoch.value, greaterThan(before));
    });

    test('the epoch is what a plaintext cache keys on', () {
      // A cache keyed by a per-PROCESS id instead — which is what the vault
      // does — keeps serving bytes decrypted under a key that has since been
      // replaced by an escrow restore.
      final a = CryptoCore.keyEpoch.value;
      CryptoCore.clearCache();
      final b = CryptoCore.keyEpoch.value;
      expect('$a|couple_intimate/x', isNot('$b|couple_intimate/x'));
    });
  });

  group('decryptBytesOffThread', () {
    test('opens a packed blob without a base64 round trip', () async {
      final key = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
      final clear = Uint8List.fromList(List.generate(5000, (i) => i % 256));
      final box = await Xchacha20.poly1305Aead().encrypt(
        clear,
        secretKey: SecretKey(key),
        aad: utf8.encode('mem_photo_full'),
      );
      final packed = packFull(EncryptedPayload(
        ciphertextB64: base64Encode(box.cipherText),
        nonceB64: base64Encode(box.nonce),
        macB64: base64Encode(box.mac.bytes),
      ),);

      // Round-trips through the same primitive the cache uses, with the key
      // supplied the way the isolate receives it.
      final out = await Xchacha20.poly1305Aead().decrypt(
        SecretBox(
          packed.sublist(40),
          nonce: packed.sublist(0, 24),
          mac: Mac(packed.sublist(24, 40)),
        ),
        secretKey: SecretKey(key),
        aad: utf8.encode('mem_photo_full'),
      );
      expect(out, clear);
    });

    test('a legacy zero-nonce blob opens with NO key at all', () async {
      // One production row is in exactly this shape. The read path keeps it
      // forever, and it must not require a key that no longer exists.
      CryptoCore.clearCache();
      final clear = Uint8List.fromList(utf8.encode('a photo from before'));
      final packed = Uint8List(40 + clear.length)..setRange(40, 40 + clear.length, clear);
      final out = await CryptoCore.decryptBytesOffThread(packed);
      expect(out, clear);
    });

    test('a blob too short to hold a nonce and MAC is rejected', () async {
      await expectLater(
        CryptoCore.decryptBytesOffThread(Uint8List(12)),
        throwsArgumentError,
      );
    });
  });

  group('refuse to upload cleartext', () {
    test('an all-zero nonce and MAC is refused', () {
      // encryptBytes with no key emits 24 zero bytes, 16 zero bytes and the
      // raw JPEG. Behind a signed URL that object IS the photograph.
      final cleartext = Uint8List(40 + 100);
      expect(
        () => MemoryPhotoRepository.refuseCleartext(cleartext),
        throwsStateError,
      );
    });

    test('a real blob passes', () {
      final real = Uint8List(140);
      real[3] = 9; // one non-zero byte inside the nonce is enough
      expect(() => MemoryPhotoRepository.refuseCleartext(real), returnsNormally);
    });
  });

  group('associated data is frozen', () {
    // Changing one of these makes every existing row and object fail Poly1305,
    // irreversibly. This is the cheapest insurance in the codebase.
    const photo = MemoryPhoto(
      id: 'ph',
      memoryId: 'mem',
      position: 0,
      coverPath: 'c',
      tilePath: 't',
      fullPath: 'f',
      mimeType: 'image/jpeg',
    );

    test('the three photo strings bind the MEMORY, not just the photo', () {
      expect(photo.coverAd, 'mem_ph_cover');
      expect(photo.tileAd, 'mem_ph_tile');
      expect(photo.fullAd, 'mem_ph_full');
    });

    test('re-parenting a photo changes its associated data', () {
      // The point of binding containment: memory_id is a plaintext column, so
      // without this an adversary with write access could move a photograph
      // into a different memory and every device would accept it.
      const moved = MemoryPhoto(
        id: 'ph',
        memoryId: 'other',
        position: 0,
        coverPath: 'c',
        tilePath: 't',
        fullPath: 'f',
        mimeType: 'image/jpeg',
      );
      expect(moved.coverAd, isNot(photo.coverAd));
    });
  });

  group('heal-on-read refuses to propagate cleartext', () {
    setUp(MemoryHeal.resetForTest);

    MemoryThread legacyRow() => MemoryThread(
          id: 'thread-1',
          proposer: 'me',
          titleCipher: Uint8List(16),
          titleNonce: Uint8List(24),
          happenedOn: DateTime.utc(2026, 3, 14),
          state: MemoryState.accepted,
          acceptedBy: null,
          acceptedAt: null,
          archivedAt: null,
          createdAt: DateTime.utc(2026, 3, 14),
          photoNonce: Uint8List(24),
        );

    test('with no couple key it declines before touching anything', () async {
      // The subtlety: decryptBytes SHORT-CIRCUITS on the legacy zero-nonce
      // signature and returns plaintext with no key at all, and one production
      // row is in exactly that state. So without this guard heal would succeed
      // on that row in plaintext mode — re-uploading a cleartext JPEG behind a
      // shareable signed URL and then nulling the original column, erasing the
      // evidence of the very thing it exists to fix.
      CryptoCore.clearCache();
      final healed = await MemoryHeal.heal(
        thread: legacyRow(),
        coupleId: 'couple-1',
        me: 'me',
      );
      expect(healed, isFalse);
    });

    test('declining does not burn the row for the rest of the session',
        () async {
      // The key usually arrives moments later, when ensureSharedKey resolves.
      // Marking the row as seen on the no-key path would mean it never healed
      // again until the process restarted.
      CryptoCore.clearCache();
      await MemoryHeal.heal(
          thread: legacyRow(), coupleId: 'couple-1', me: 'me',);
      // Reaching the guard a second time proves it was not added to _seen —
      // that check runs FIRST and would have returned before the key lookup.
      final second = await MemoryHeal.heal(
          thread: legacyRow(), coupleId: 'couple-1', me: 'me',);
      expect(second, isFalse);
      expect(MemoryHeal.debugSeen, isEmpty);
    });
  });

  group('decode queue', () {
    setUp(MediaDecodeQueue.resetForTest);

    test('work whose cell scrolled away is dropped, not run', () async {
      var ran = 0;
      final results = await Future.wait([
        for (var i = 0; i < 20; i++)
          MediaDecodeQueue.run<int>(
            'job$i',
            // Only the first four are still on screen by the time the queue
            // reaches them. isWanted is asked at DEQUEUE, which is the entire
            // difference between this and a plain queue.
            () => i < 4,
            () async {
              ran++;
              return i;
            },
          ),
      ]);
      expect(ran, 4);
      expect(results.whereType<int>().length, 4);
      expect(results.where((r) => r == null).length, 16);
    });

    test('never runs more than two at once', () async {
      var live = 0;
      var peak = 0;
      await Future.wait([
        for (var i = 0; i < 12; i++)
          MediaDecodeQueue.run<void>('c$i', () => true, () async {
            live++;
            peak = live > peak ? live : peak;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            live--;
          }),
      ]);
      expect(peak, lessThanOrEqualTo(2));
    });

    test('a duplicate id does not enqueue twice', () async {
      var ran = 0;
      final both = await Future.wait([
        MediaDecodeQueue.run<int>('same', () => true, () async {
          ran++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 1;
        }),
        MediaDecodeQueue.run<int>('same', () => true, () async {
          ran++;
          return 2;
        }),
      ]);
      expect(ran, 1);
      // Both callers get the ONE result. This used to assert that the duplicate
      // received null, which is the behaviour that painted a permanently blank
      // memory cover: null is also what a dropped job returns, so the caller
      // read "somebody else is loading this" as "finished, nothing to show".
      expect(both, [1, 1]);
    });

    test('a failing job does not wedge the queue', () async {
      await expectLater(
        MediaDecodeQueue.run<void>('boom', () => true, () async {
          throw StateError('decode failed');
        }),
        throwsStateError,
      );
      final after =
          await MediaDecodeQueue.run<int>('after', () => true, () async => 7);
      expect(after, 7);
    });
  });
}
