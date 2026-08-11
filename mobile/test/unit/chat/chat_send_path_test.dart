import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The shape of the send path, which behaviour cannot reach.
///
/// What a picked photo passes through on its way to the conversation, and
/// which callback the input bar is handed, are both invisible without booting
/// the whole chat against a live Supabase. The rules these steps enforce —
/// bounded uploads, per-item failure — are executed in chat_batch_send_test.
void main() {
  final bar =
      File('lib/features/chat/widgets/chat_input_bar.dart').readAsStringSync();
  final chat = File('lib/features/chat/chat_screen.dart').readAsStringSync();

  group('picked media goes straight to the chat', () {
    test('the send path has no filter step left in it', () {
      // ratio → filters → chat was three screens to send one photo, and the
      // filter editor is the step that made it three. It is still reachable
      // from the avatar and the touch map, which is why the screen survives.
      expect(bar.contains('enhanceContext'), isFalse,
          reason: 'the filter editor is back in the send path',);
      expect(bar.contains('PhotoPickerService.pick('), isFalse,
          reason: 'pick() crops and enhances; the chat sends what was picked',);
    });

    test('one action opens one picker for photos and videos together', () {
      expect(bar, contains('PhotoPickerService.pickMedia('));
      // Two gallery entries in the sheet is the split flow this replaced.
      expect(bar.contains('ImageSource.gallery'), isFalse);
    });

    test('the pick is handed to the queue, not awaited', () {
      expect(chat, contains('onSendMedia: (items) =>'));
      expect(chat, contains('ChatSendQueue.instance.enqueueAll'));
    });
  });

  group('a message can be copied', () {
    test('copy hangs off the existing selection, not a new gesture', () {
      // Long-press already opens the selection bar, which is where reply and
      // save live. A second long-press meaning something else would be a
      // second way to do the same thing.
      final at = chat.indexOf(r'${_selection.length} selected');
      expect(at, greaterThan(-1), reason: 'the selection bar should exist');
      expect(chat.substring(at, at + 1400), contains('_copyMessage(one)'));
    });

    test('what lands on the clipboard is the message, not a label', () {
      // previewText() answers '📷 Photo' for a picture, and pasting that into
      // another app is worse than the button not being there.
      expect(chat, contains('Clipboard.setData'));
      expect(chat, contains("static String _copyableText(Message m) => (m.body ?? '').trim();"));
      expect(chat, contains('if (_copyableText(one).isNotEmpty)'),
          reason: 'the button has to be hidden where there is nothing to copy',);
    });
  });
}
