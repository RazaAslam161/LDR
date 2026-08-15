import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// A message that arrives live has never been through a page load, so nothing
/// signed its media.
///
/// fetch()/fetchSince() warm a whole page in one round trip; realtime and the
/// broadcast fast path warm nothing. voiceUrl came back null, and the bubble
/// rendered "🎙️ voice unavailable" until a resume or a reopen re-fetched the
/// page: "they show unavailable for a while before delivering".
void main() {
  Message msg({String? image, String? voice, String? video}) => Message(
        id: 'm1',
        senderId: 'u1',
        createdAt: DateTime(2026, 8, 11),
        kind: video != null ? 'video' : (voice != null ? 'voice' : 'image'),
        imagePath: image,
        voicePath: voice,
        videoPath: video,
      );

  group('what a message needs signed', () {
    test('a voice note names its couple_media path', () {
      expect(msg(voice: 'c1/voice_1.m4a').mediaPaths, ['c1/voice_1.m4a']);
      expect(msg(voice: 'c1/voice_1.m4a').privatePaths, isEmpty);
    });

    test('a video names the PRIVATE bucket instead', () {
      // Two buckets, two signing calls. Video warmed against couple_media
      // would sign nothing and leave the tap on a round trip.
      expect(msg(video: 'c1/vid_1.mp4').privatePaths, ['c1/vid_1.mp4']);
      expect(msg(video: 'c1/vid_1.mp4').mediaPaths, isEmpty);
    });

    test('a text message needs nothing', () {
      expect(msg().mediaPaths, isEmpty);
      expect(msg().privatePaths, isEmpty);
    });

    test('a legacy public URL is reduced to the object name', () {
      // Rows written before the bucket closed hold a whole URL.
      expect(
          msg(image: 'https://x.supabase.co/storage/v1/object/public/'
                  'couple_media/c1/img_1.jpg',)
              .mediaPaths,
          ['c1/img_1.jpg'],);
    });
  });

  test('the chat signs a live message before its bubble asks', () {
    // Not reachable without a live socket and a live Supabase, and it is the
    // step whose absence was the bug.
    final chat = File('lib/features/chat/chat_screen.dart').readAsStringSync();
    expect(chat, contains('unawaited(_warmMedia(m));'));
    expect(chat, contains('await ChatRepository.warmMedia([m]);'));
  });

  test('video is signed with the page, not on the tap', () {
    final repo =
        File('lib/features/chat/chat_repository.dart').readAsStringSync();
    expect(repo, contains('MediaUrls.warm(privateBucket'));
    // createSignedUrl on tap is the round trip that made opening one slow.
    expect(repo.contains('createSignedUrl('), isFalse,
        reason: 'sign through MediaUrls so the cache can answer instead',);
  });
}
