import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/vault/vault_repository.dart';
import 'package:miles/features/vault/vault_thumb_backfill.dart';

/// Why a saved video showed no preview, and what now heals it.
///
/// Production said this was every video, not an edge case: 8 of 8 vault videos
/// carried no `thumb_path`, against 32 of 32 photos that did. The cause is one
/// line of `gridPath` meeting one branch of `saveMedia` — the save derived a
/// tile only for images, so `thumb_path` was always null for a video, so
/// `gridPath` returned null by design and the grid had nothing to paint but a
/// glyph.
void main() {
  VaultItem item({
    String id = 'v1',
    String type = 'saved_video',
    String? mime = 'video/mp4',
    String? storagePath = 'uid/vault/v1.mp4',
    String? thumbPath,
  }) =>
      VaultItem(
        id: id,
        type: type,
        createdAt: DateTime(2026),
        mimeType: mime,
        storagePath: storagePath,
        thumbPath: thumbPath,
      );

  group('why the tile was blank', () {
    test('a video with no thumbnail has no grid path at all', () {
      // Not a bug in the tile — the tile is doing what it is told. This is the
      // line the symptom actually comes from.
      expect(item().gridPath, isNull);
    });

    test('a video WITH a thumbnail paints it', () {
      expect(item(thumbPath: 'uid/vault/thumb/v1.jpg').gridPath,
          'uid/vault/thumb/v1.jpg',);
    });

    test('a photo never had this problem — it falls back to its original', () {
      expect(
        item(type: 'saved_photo', mime: 'image/jpeg', storagePath: 'uid/v.jpg')
            .gridPath,
        'uid/v.jpg',
        reason: 'which is why photos rendered and only videos did not',
      );
    });
  });

  group('what the backfill will touch', () {
    setUp(VaultThumbBackfill.resetForTest);

    test('a video missing its poster', () {
      expect(VaultThumbBackfill.wants(item()), isTrue);
    });

    test('not one that already has a poster', () {
      expect(
        VaultThumbBackfill.wants(item(thumbPath: 'uid/vault/thumb/v1.jpg')),
        isFalse,
      );
    });

    test('not audio — there is no frame in an m4a to extract', () {
      expect(
        VaultThumbBackfill.wants(
            item(type: 'saved_voice', mime: 'audio/mp4'),),
        isFalse,
      );
    });

    test('not a legacy bookmark row, which owns no bytes to read', () {
      expect(VaultThumbBackfill.wants(item(storagePath: null)), isFalse);
    });

    test('not a photo', () {
      expect(
        VaultThumbBackfill.wants(
            item(type: 'saved_photo', mime: 'image/jpeg'),),
        isFalse,
      );
    });
  });
}
