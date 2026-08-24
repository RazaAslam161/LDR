import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/call_controller.dart';

/// The cross-version decision, and the reason it is a pure function.
///
/// Production is ahead of this repo — builds 49, 51 and 52 are on real handsets
/// and predate the second video m-line. A call between versions must degrade to
/// the old single-sender swap, not break. `sdpHasSecondVideoLine` is what picks
/// between them, and it is the one decision here that CANNOT be checked on the
/// machine this was written on: there is no Android SDK, so there is no second
/// handset to negotiate against. Testing it against real SDP shapes is the only
/// verification available, so it is done properly rather than sketched.
///
/// The SDP below is trimmed to the lines that matter — section headers, the
/// mid attributes and the directions — but the structure is exactly what
/// unified-plan produces.
const _oldPeerAnswer = '''
v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0 1
m=audio 9 UDP/TLS/RTP/SAVPF 111
c=IN IP4 0.0.0.0
a=mid:0
a=sendrecv
m=video 9 UDP/TLS/RTP/SAVPF 96 97
c=IN IP4 0.0.0.0
a=mid:1
a=sendrecv
a=msid:stream-a camera-track
''';

const _newPeerAnswer = '''
v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0 1 2
m=audio 9 UDP/TLS/RTP/SAVPF 111
c=IN IP4 0.0.0.0
a=mid:0
a=sendrecv
m=video 9 UDP/TLS/RTP/SAVPF 96 97
c=IN IP4 0.0.0.0
a=mid:1
a=sendrecv
a=msid:stream-a camera-track
m=video 9 UDP/TLS/RTP/SAVPF 96 97
c=IN IP4 0.0.0.0
a=mid:2
a=sendrecv
''';

/// The old peer as CALLEE, answering our three-section offer. It has no
/// transceiver for m2, so libwebrtc creates a recvonly one and the section is
/// mirrored back — it can receive our screen even though it will not render it.
const _oldPeerCalleeAnswer = '''
v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0 1 2
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=mid:0
a=sendrecv
m=video 9 UDP/TLS/RTP/SAVPF 96 97
a=mid:1
a=sendrecv
a=msid:stream-a camera-track
m=video 9 UDP/TLS/RTP/SAVPF 96 97
a=mid:2
a=recvonly
''';

void main() {
  group('sdpHasSecondVideoLine', () {
    test('a peer that negotiated two video sections takes the second line', () {
      expect(CallController.sdpHasSecondVideoLine(_newPeerAnswer), isTrue);
    });

    // The regression this exists to prevent: sharing onto a sender the far side
    // never negotiated sends into nothing, and looks from the sharer's side
    // like a share that simply did not arrive.
    test('a build older than the second m-line falls back', () {
      expect(CallController.sdpHasSecondVideoLine(_oldPeerAnswer), isFalse);
    });

    // The other direction: WE offered three sections to an old callee. It
    // mirrors the section back as recvonly, so it can receive — the count is
    // what matters, not the direction.
    test('an old callee that mirrors our third section still counts', () {
      expect(CallController.sdpHasSecondVideoLine(_oldPeerCalleeAnswer), isTrue);
    });

    test('no remote description yet is not a yes', () {
      expect(CallController.sdpHasSecondVideoLine(null), isFalse);
      expect(CallController.sdpHasSecondVideoLine(''), isFalse);
    });

    test('an audio-only call has no video section at all', () {
      expect(
        CallController.sdpHasSecondVideoLine(
          'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\n',
        ),
        isFalse,
      );
    });

    // `m=` is only legal at the start of a line. Counting occurrences anywhere
    // in the blob would let an attribute VALUE that happens to contain the text
    // vote — and `a=msid` values are remote-controlled strings.
    test('the text m=video inside an attribute value does not count', () {
      const spoofed = '''
v=0
m=video 9 UDP/TLS/RTP/SAVPF 96
a=mid:1
a=msid:m=video m=video
a=label:m=video
''';
      expect(CallController.sdpHasSecondVideoLine(spoofed), isFalse);
    });

    test('CRLF line endings, which is what the wire actually carries', () {
      final crlf = _newPeerAnswer.replaceAll('\n', '\r\n');
      expect(CallController.sdpHasSecondVideoLine(crlf), isTrue);
      final oldCrlf = _oldPeerAnswer.replaceAll('\n', '\r\n');
      expect(CallController.sdpHasSecondVideoLine(oldCrlf), isFalse);
    });

    test('three video sections is still a yes, not an off-by-one', () {
      expect(
        CallController.sdpHasSecondVideoLine(
          '$_newPeerAnswer\nm=video 9 UDP/TLS/RTP/SAVPF 96\na=mid:3\n',
        ),
        isTrue,
      );
    });
  });
}
