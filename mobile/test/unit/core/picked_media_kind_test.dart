import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/photo_picker_service.dart';

/// Which bucket a picked file goes to, and which kind of message it becomes.
///
/// A wrong answer is not recoverable: a video uploaded as kind='image' renders
/// as a broken picture in the conversation forever, and the sender has already
/// moved on. The one picker hands photos and videos back together, so this
/// runs on every item of every pick.
void main() {
  test('a video is recognised by its extension, in any case', () {
    for (final name in [
      '/cache/VID_0001.mp4',
      '/cache/clip.MOV',
      '/cache/x.3gp',
      '/cache/x.webm',
      '/cache/x.mkv',
    ]) {
      expect(PhotoPickerService.isVideoPick(name, null), isTrue, reason: name);
    }
  });

  test('a photo is not', () {
    for (final name in ['/cache/a.jpg', '/cache/a.HEIC', '/cache/a.png']) {
      expect(PhotoPickerService.isVideoPick(name, null), isFalse, reason: name);
    }
  });

  test('the extension wins over a mime type that disagrees', () {
    // Android's content resolver hands back whatever the source app declared,
    // and the file image_picker actually copied into the cache is the one
    // about to be uploaded.
    expect(PhotoPickerService.isVideoPick('/cache/a.jpg', 'video/mp4'), isFalse);
    expect(PhotoPickerService.isVideoPick('/cache/a.mp4', 'image/jpeg'), isTrue);
  });

  test('with no usable extension it falls back to the mime type', () {
    expect(PhotoPickerService.isVideoPick('/cache/1000012', 'video/mp4'),
        isTrue,);
    expect(PhotoPickerService.isVideoPick('/cache/1000012', 'image/jpeg'),
        isFalse,);
    // Neither says video: an unknown blob sent as a photo shows a broken tile,
    // sent as a video it lands in the private bucket and plays nothing. The
    // photo path is the one the gallery mostly means.
    expect(PhotoPickerService.isVideoPick('/cache/1000012', null), isFalse);
    expect(PhotoPickerService.isVideoPick('/cache/blob.dat', 'application/octet-stream'),
        isFalse,);
  });

  test('every picker entry point asks for the gallery, not a file browser', () {
    // Which Android intent gets fired is decided by one bool inside a plugin,
    // and no widget test can see it: the plugin defaults it to false, which is
    // ACTION_GET_CONTENT — the document provider. "sending multiple pics and
    // videos takes me to the phone drive or file manager" was that default.
    final src =
        File('lib/core/services/photo_picker_service.dart').readAsStringSync();
    expect(src, contains('impl.useAndroidPhotoPicker = true'));
    // One missed entry point is one action that still opens the file manager.
    expect('_useSystemGallery();'.allMatches(src).length, 3,
        reason: 'pick, pickMedia and pickVideo each open a system picker',);
  });
}
