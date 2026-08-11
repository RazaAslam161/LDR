import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/document_picker_service.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_send_queue.dart';

/// Sending a document. "there is no option of send documents , files or
/// anything else in the app."
///
/// The two things a document has that a photo does not are a name and a bucket
/// of its own, and both are easy to lose: the name is not recoverable from the
/// path (the provider caches under one of its own), and putting the file in
/// couple_media would mean widening that bucket's mime whitelist for every
/// photo in the conversation.
void main() {
  final q = ChatSendQueue.instance;
  late Directory tmp;
  late File doc;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('docs');
    doc = File('${tmp.path}/cached_0192.bin')..writeAsBytesSync([1, 2, 3]);
    for (final s in q.pending.toList()) {
      q.discard(s.id);
    }
  });

  tearDown(() {
    q.uploader = null;
    tmp.deleteSync(recursive: true);
  });

  void hangingUploader() {
    final held = Completer<void>();
    addTearDown(() async {
      held.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    q.uploader = (_) => held.future;
  }

  test('a document keeps the name it was picked with', () {
    // The path is a cache artefact — 'cached_0192.bin' is what the provider
    // called it, and it is not what the bubble should say.
    hangingUploader();
    q.enqueueFiles('couple-1', [(file: doc, name: 'Q3 budget.xlsx')]);

    expect(q.pending.single.kind, 'file');
    expect(q.pending.single.fileName, 'Q3 budget.xlsx');
  });

  test('the reply belongs to the first document only', () {
    // Same rule as a gallery batch: three files each quoting the same message
    // is three copies of it down the conversation.
    hangingUploader();
    q.enqueueFiles(
        'couple-1',
        [
          (file: doc, name: 'a.pdf'),
          (file: doc, name: 'b.pdf'),
          (file: doc, name: 'c.pdf'),
        ],
        replyToId: 'msg-1',);

    expect(q.pending.map((s) => s.replyToId), ['msg-1', null, null]);
  });

  test('a file message renders as its name for a client that predates it', () {
    // kind='file' means nothing to a build already in the field, and it falls
    // through to rendering body. Putting the name there is the difference
    // between a filename and an empty bubble on every phone not yet updated.
    final m = Message(
      id: 'm1',
      senderId: 'u1',
      createdAt: DateTime(2026, 8, 11),
      kind: 'file',
      body: 'lease.pdf',
      filePath: 'c1/file_1.pdf',
      fileSize: 2048,
    );
    expect(m.body, 'lease.pdf');
    expect(m.previewText(), '📎 lease.pdf');
  });

  test('the size in the bubble is one a person reads', () {
    expect(DocumentPickerService.formatBytes(512), '512 B');
    expect(DocumentPickerService.formatBytes(2048), '2.0 KB');
    expect(DocumentPickerService.formatBytes(26214400), '25 MB');
  });

  test('documents are a separate action from the gallery', () {
    // WhatsApp has both because they are different intents. One button doing
    // both is how the photo picker ended up in the file manager.
    final bar =
        File('lib/features/chat/widgets/chat_input_bar.dart').readAsStringSync();
    expect(bar, contains('DocumentPickerService.pick('));
    expect(bar, contains('PhotoPickerService.pickMedia('));
    expect(bar, contains("Text('Document'"));
  });

  test('documents go to their own bucket, signed like everything else', () {
    final repo =
        File('lib/features/chat/chat_repository.dart').readAsStringSync();
    expect(repo, contains('storage.from(filesBucket)'));
    expect(repo, contains('MediaUrls.sign(filesBucket'));
  });
}
