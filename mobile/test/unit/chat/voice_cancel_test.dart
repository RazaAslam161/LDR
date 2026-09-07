import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The composer has told people to "slide up to cancel" since voice notes
/// shipped, and no cancel gesture existed.
///
/// `onLongPressEnd` sent unconditionally, so the only way out of a recording
/// you regretted was to send it and then delete it from both phones — and the
/// file stayed in the cache either way, where the data export writes it out.
void main() {
  final src = File('lib/features/chat/widgets/chat_input_bar.dart')
      .readAsStringSync();

  String fn(String head) {
    final at = src.indexOf(head);
    expect(at, greaterThan(-1), reason: '$head not found');
    return src.substring(at, src.indexOf(RegExp(r'\n  \}\r?\n'), at));
  }

  test('sliding up arms a cancel, and releasing there honours it', () {
    expect(src, contains('onLongPressMoveUpdate'));
    expect(src, contains('_stopRecording(cancel: _cancelArmed)'),
        reason: 'the release has to READ the gesture, not ignore it',);
    expect(src, contains('localOffsetFromOrigin.dy <= -_cancelSlide'));
  });

  test('a pointer cancel stops the recorder without destroying the note', () {
    // This pinned `_stopRecording(cancel: true)`, on the belief that the arena
    // could still take the press back. It cannot: once a long press is
    // ACCEPTED at 500ms the arena is resolved, and the only thing left that
    // reaches this handler is a synthesized PointerCancelEvent — which the
    // app's own Navigator sends on every route push and pop. Treating that as
    // "the user threw the note away" deleted a recording nobody discarded.
    expect(src,
        contains('onLongPressCancel: _muteHold ? null : _stopRecording'),);
    expect(src, isNot(contains('onLongPressCancel: () => _stopRecording(cancel: true)')));
  });

  test('with text in the box, no long-press callback is live at all', () {
    // Nulling only onLongPressStart left the recognizer in the arena — it is
    // built if ANY long-press callback is non-null — so it won at 500ms and
    // REJECTED the tap recognizer: a send button that opened no microphone and
    // sent nothing on a half-second press.
    for (final cb in const [
      'onLongPressStart:',
      'onLongPressMoveUpdate: _muteHold',
      'onLongPressEnd: _muteHold',
      'onLongPressCancel: _muteHold ? null',
    ]) {
      expect(src, contains(cb), reason: cb);
    }
    // ...and never mid-recording. RawGestureDetector re-uses the LIVE
    // recognizer across a rebuild and re-assigns its callbacks, so text
    // arriving while the finger is down would null the release handler and
    // leave the microphone open with nothing able to stop it.
    expect(src, contains('bool get _muteHold => _hasText && !_recording;'));
  });

  test('holding the SEND button never opens the microphone', () {
    expect(src, contains('_muteHold ? null : (_) => _startRecording()'),
        reason: 'with text in the box it is a send button',);
  });

  test('the banner says which release does what', () {
    expect(src, contains("'Release to cancel'"));
    expect(src, contains("'Slide up to cancel · release to send'"),
        reason: 'and the promise it has always made stays on screen',);
  });

  test('a cancelled recording is deleted, and a failed delete is reported', () {
    final stop = fn('Future<void> _stopRecording({bool cancel = false}) async {');
    expect(stop, contains('await file.delete()'),
        reason: 'a recording of the room the user decided nobody should have',);
    expect(stop, contains("kind: 'voice-cancel-delete'"));
    // The old shape returned before the file was ever named.
    expect(stop, isNot(contains('if (cancel || path == null) return;')));
  });
}
