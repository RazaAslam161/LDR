import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';

/// Reading a voice note's length out of the file the recorder wrote.
///
/// The recorder reports no duration at all (record 7.1.0's `stop()` returns the
/// path and nothing else), so the length comes from the recording's own mvhd
/// box. That parse sits in the send path of the app's most-used feature, so
/// what matters here is as much what it does with a file it cannot read as what
/// it does with one it can: every failure must answer null and let the note
/// send, never throw and never spin.
///
/// CAVEAT, stated plainly: these fixtures are built to the ISO base media file
/// format layout, not captured from a handset — no device recording and no
/// ffmpeg were available here. They pin the box walk and the field offsets,
/// which is the part that can be wrong in a way a reader would not notice. They
/// do NOT prove that record/Android writes a truthful duration into mvhd; only
/// recording a note on a phone settles that.
void main() {
  List<int> be32(int v) =>
      [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
  List<int> be64(int v) => [...be32(v >> 32), ...be32(v & 0xffffffff)];

  List<int> box(String type, List<int> payload) =>
      [...be32(8 + payload.length), ...type.codeUnits, ...payload];

  // A real v0 mvhd payload is 100 bytes; a v1 one is 112. The tail after the
  // duration is rate, volume, the display matrix and the next track id —
  // nothing this reads, but the sizes have to be honest or the box walk is
  // being tested against a shape that does not occur.
  List<int> mvhd0(int timescale, int duration) => [
        0, 0, 0, 0, // version 0, no flags
        ...be32(0), ...be32(0), // created, modified
        ...be32(timescale),
        ...be32(duration),
        ...List.filled(80, 0),
      ];

  List<int> mvhd1(int timescale, int duration) => [
        1, 0, 0, 0, // version 1: 64-bit dates and duration
        ...be64(0), ...be64(0),
        ...be32(timescale),
        ...be64(duration),
        ...List.filled(80, 0),
      ];

  /// Laid out the way a phone recorder writes one: the audio first and the
  /// header LAST, because the encoder does not know the duration until it
  /// stops. A reader that only looked at the front of the file would find
  /// nothing in a real recording.
  List<int> m4a(List<int> mvhd, {int audioBytes = 64000}) => [
        ...box('ftyp', 'M4A isom'.codeUnits),
        ...box('free', const []),
        ...box('mdat', List.filled(audioBytes, 0x41)),
        ...box('moov', [...box('mvhd', mvhd), ...box('trak', List.filled(64, 0))]),
      ];

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('voicedur'));
  tearDown(() async => dir.delete(recursive: true));

  Future<File> write(List<int> bytes, {String name = 'v.m4a'}) async {
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  test('reads the length past a large mdat, where the header really sits',
      () async {
    final f = await write(m4a(mvhd0(1000, 7400)));
    expect(await ChatRepository.m4aDurationMs(f), 7400);
  });

  test('scales by the timescale rather than assuming milliseconds', () async {
    // 44100 ticks per second is what an AAC recording actually carries; read
    // as milliseconds this three-second note would come out as 132300.
    final f = await write(m4a(mvhd0(44100, 44100 * 3)));
    expect(await ChatRepository.m4aDurationMs(f), 3000);
  });

  test('reads a 64-bit version 1 header', () async {
    final f = await write(m4a(mvhd1(48000, 48000 * 9)));
    expect(await ChatRepository.m4aDurationMs(f), 9000);
  });

  test('a two second note is two seconds, not one or three', () async {
    // The resolution the defect was reported at.
    final f = await write(m4a(mvhd0(1000, 2000)));
    expect(await ChatRepository.m4aDurationMs(f), 2000);
  });

  test("the container's unknown-duration sentinel is not a length", () async {
    final f = await write(m4a(mvhd0(1000, 0xFFFFFFFF)));
    expect(await ChatRepository.m4aDurationMs(f), isNull);
  });

  test('a zero timescale does not divide by zero', () async {
    final f = await write(m4a(mvhd0(0, 7400)));
    expect(await ChatRepository.m4aDurationMs(f), isNull);
  });

  test('a file with no moov at all answers null', () async {
    final f = await write([...box('ftyp', 'M4A isom'.codeUnits),
      ...box('mdat', List.filled(1000, 0x41)),]);
    expect(await ChatRepository.m4aDurationMs(f), isNull);
  });

  test('a moov with no mvhd inside it answers null', () async {
    final f = await write([
      ...box('ftyp', 'M4A isom'.codeUnits),
      ...box('moov', box('trak', List.filled(64, 0))),
    ]);
    expect(await ChatRepository.m4aDurationMs(f), isNull);
  });

  test('bytes that are not a container at all answer null, and do not throw',
      () async {
    final f = await write(List.generate(4096, (i) => (i * 37) & 0xff));
    expect(await ChatRepository.m4aDurationMs(f), isNull);
  });

  test('an empty recording answers null', () async {
    final f = await write(const []);
    expect(await ChatRepository.m4aDurationMs(f), isNull);
  });

  test('a file that is not there answers null rather than throwing', () async {
    // The send path calls this before the upload; an exception here would
    // become a voice note that did not send because its label could not be
    // worked out.
    expect(
      await ChatRepository.m4aDurationMs(File('${dir.path}/gone.m4a')),
      isNull,
    );
  });

  test('a box claiming to run past the end of the file terminates', () async {
    // A truncated upload or a half-flushed recording. The walk must stop, not
    // read off the end and not loop.
    final good = m4a(mvhd0(1000, 7400));
    final f = await write(good.sublist(0, good.length - 40));
    expect(
      await ChatRepository.m4aDurationMs(f).timeout(const Duration(seconds: 5)),
      isNull,
    );
  });

  test('a zero-length box header cannot spin the walk forever', () async {
    // size 0 means "runs to the end of the parent". Treated as an increment
    // instead, the cursor would never advance.
    final f = await write([
      ...be32(0), ...'skip'.codeUnits,
      ...List.filled(64, 0),
    ]);
    expect(
      await ChatRepository.m4aDurationMs(f).timeout(const Duration(seconds: 5)),
      isNull,
    );
  });


  // The one this suite missed, and the reason a whole build shipped without
  // durations: every test above hands VoiceNoteBubble a durationMs directly, so
  // they all passed while chat_screen never passed one. The column was written,
  // the row carried it, the model parsed it, the widget could render it — and
  // the call site dropped it on the floor between them.
  //
  // This pins the boundary the widget tests cannot see: a row as PostgREST
  // actually returns it must arrive at the model with its duration intact, so
  // there is something for the bubble to be given.
  test('a row from the server carries its voice duration into the model', () {
    final m = Message.fromJson(<String, dynamic>{
      'id': '11111111-1111-1111-1111-111111111111',
      'sender_id': '22222222-2222-2222-2222-222222222222',
      'created_at': '2026-08-16T22:49:33.905435+00:00',
      'kind': 'voice',
      'voice_path': 'couple/voice/x.m4a',
      // Postgres integer over JSON, exactly the shape observed in production:
      // select voice_duration_ms -> 5364.
      'voice_duration_ms': 5364,
    });

    expect(m.voiceDurationMs, 5364);
  });

  test('a note sent before the column existed parses as null, not zero', () {
    final m = Message.fromJson(<String, dynamic>{
      'id': '33333333-3333-3333-3333-333333333333',
      'sender_id': '22222222-2222-2222-2222-222222222222',
      'created_at': '2026-08-16T21:18:02.787751+00:00',
      'kind': 'voice',
      'voice_path': 'couple/voice/old.m4a',
      'voice_duration_ms': null,
    });

    // Null and 0 render differently on purpose — null shows no label at all,
    // and 0 would claim a real recording is instantaneous.
    expect(m.voiceDurationMs, isNull);
  });
}
