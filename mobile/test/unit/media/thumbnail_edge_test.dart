import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:miles/core/media/media_decode.dart';
import 'package:miles/core/media/thumbnails.dart';

/// The header probe that decides whether an existing thumbnail is too small.
///
/// It is the whole gate on `ThumbBackfill.resize`: answer too big and no
/// legacy thumbnail is ever re-derived, so raising the edge silently helps
/// nobody's existing conversation; answer too small and every dwell re-uploads
/// an object that was already correct.
void main() {
  group('Thumbnails.longestEdge', () {
    test('reads the LONG edge of a landscape JPEG from its header', () {
      final bytes = img.encodeJpg(img.Image(width: 640, height: 400));
      expect(Thumbnails.longestEdge(bytes), 640);
    });

    test('reads the LONG edge of a portrait JPEG, which is its height', () {
      // The case the old 400px constant got most wrong: a portrait thumbnail
      // capped at 400 on its long edge is only 300 wide, so the 220dp bubble
      // was blowing it up about twofold.
      final bytes = img.encodeJpg(img.Image(width: 300, height: 400));
      expect(Thumbnails.longestEdge(bytes), 400);
    });

    test('reads a PNG too, not just JPEG', () {
      final bytes = img.encodePng(img.Image(width: 128, height: 64));
      expect(Thumbnails.longestEdge(bytes), 128);
    });

    test('returns null rather than throwing on bytes that are not an image',
        () {
      expect(Thumbnails.longestEdge(img.encodeJpg(img.Image(width: 1, height: 1))
          .sublist(0, 4)), isNull,);
    });

    test('an object made at the CURRENT edge is not undersized', () {
      // The resize gate is `edge < Thumbnails.maxEdge`, so this is the
      // assertion that stops a correct thumbnail being re-uploaded forever.
      final bytes = img.encodeJpg(
          img.Image(width: Thumbnails.maxEdge, height: 400),);
      expect(Thumbnails.longestEdge(bytes), Thumbnails.maxEdge);
      expect(Thumbnails.longestEdge(bytes)! < Thumbnails.maxEdge, isFalse);
    });

    test('an object made at the OLD 400 edge is undersized', () {
      final bytes = img.encodeJpg(img.Image(width: 400, height: 300));
      expect(Thumbnails.longestEdge(bytes)! < Thumbnails.maxEdge, isTrue);
    });
  });

  test('the shared decode bound matches the object it decodes', () {
    // Two constants that must move together: the decode is bounded at the
    // object's own long edge, so landscape decodes 1:1 and portrait decodes at
    // its native width (ResizeImage does not upscale). Split them and every
    // surface pays a resize for nothing.
    expect(kThumbDecodePx, Thumbnails.maxEdge);
  });
}
