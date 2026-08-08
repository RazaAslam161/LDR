import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:miles/features/chat/camera_bake.dart';

/// The bake sits between the shutter and the photo a partner receives. Its one
/// promise is that a capture is never lost: whatever goes wrong, bytes come
/// back. The other thing worth pinning is the fast path — it is the difference
/// between shipping the sensor's own JPEG and re-encoding a generation away.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('bake_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A small photo-like JPEG on disk, since bakeSnap now reads the file itself.
  File jpegOnDisk({int w = 64, int h = 48}) {
    final image = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        image.setPixelRgb(x, y, x * 4 % 256, y * 5 % 256, (x + y) % 256);
      }
    }
    final f = File('${tmp.path}/in.jpg')
      ..writeAsBytesSync(img.encodeJpg(image, quality: 92));
    return f;
  }

  BakeRequest req(
    String path, {
    String filterId = 'none',
    bool mirror = false,
    List<double>? matrix,
  }) =>
      BakeRequest(
        path: path,
        filterId: filterId,
        matrix: matrix ??
            [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
        blurSigma: 0,
        overlayArgb: null,
        overlayScreen: false,
        hasGrain: false,
        grainIntensity: 0,
        mirror: mirror,
      );

  test('no filter and no mirror returns the sensor bytes untouched', () {
    // The whole point of the fast path: byte-identical, so there is no decode,
    // no re-encode and no generation loss.
    final f = jpegOnDisk();
    final original = f.readAsBytesSync();
    expect(bakeSnap(req(f.path)), original);
  });

  test('a mirror alone still costs a re-encode', () {
    // Worth knowing rather than assuming: mirroring cannot be done to a JPEG
    // in place, so a front-camera shot leaves the fast path even with no
    // filter. This is why the default lens matters.
    final f = jpegOnDisk();
    final out = bakeSnap(req(f.path, mirror: true));
    expect(out, isNot(f.readAsBytesSync()));

    final before = img.decodeImage(f.readAsBytesSync())!;
    final after = img.decodeImage(out)!;
    expect(after.width, before.width);
    expect(after.height, before.height);
    // Left edge of the output should be the right edge of the input.
    expect(after.getPixel(0, 0).r, closeTo(before.getPixel(63, 0).r, 24));
  });

  test('a filter changes the pixels', () {
    final f = jpegOnDisk();
    // Invert red — unmistakable, and it proves the matrix is actually applied.
    final out = bakeSnap(req(
      f.path,
      filterId: 'test',
      matrix: [-1, 0, 0, 0, 255, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
    ));
    final before = img.decodeImage(f.readAsBytesSync())!;
    final after = img.decodeImage(out)!;
    expect(after.getPixel(10, 10).r, isNot(closeTo(before.getPixel(10, 10).r, 8)));
  });

  test('a missing file throws rather than returning a broken photo', () {
    // The caller catches this and keeps the sensor frame. Silently returning
    // empty bytes would send a corrupt image to a partner.
    expect(() => bakeSnap(req('${tmp.path}/nope.jpg')), throwsA(anything));
  });

  test('undecodable bytes come back as-is instead of being dropped', () {
    final f = File('${tmp.path}/junk.jpg')
      ..writeAsBytesSync(List<int>.filled(64, 7));
    final out = bakeSnap(req(f.path, filterId: 'test', mirror: true));
    expect(out, f.readAsBytesSync());
  });

  test('the output cap is not above what the camera captures', () {
    // maxWidth sat at 2560 while capture was 2160 wide, so the resize never
    // helped and every filtered shot paid for the check. If someone raises the
    // preset again, this is the line that has to move with it.
    expect(BakeRequest.maxWidth, lessThanOrEqualTo(1920));
    expect(BakeRequest.jpegQuality, lessThan(95));
  });
}
