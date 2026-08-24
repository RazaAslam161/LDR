import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/voice_peaks.dart';

/// The encoder answers to a column that is already in production.
///
/// `messages.voice_peaks` shipped on 2026-08-20 with its contract written into
/// its column comment, and with a CHECK that refuses anything over 256
/// characters. A refused INSERT does not drop the column — it fails the whole
/// row and the voice note is gone — so "the output always fits" is tested here
/// as a property, not assumed from the arithmetic.
void main() {
  group('encode', () {
    test('always emits exactly 56 bars, however many samples came in', () {
      for (final n in [1, 3, 55, 56, 57, 112, 900]) {
        final levels = List<double>.generate(n, (i) => (i % 9 + 1) / 10);
        final encoded = VoicePeaks.encode(levels);
        expect(encoded, isNotNull, reason: '$n samples');
        expect(base64Decode(encoded!).length, VoicePeaks.bars,
            reason: '$n samples',);
      }
    });

    test('a bar takes the LOUDEST sample in its bucket, not the mean', () {
      // 112 samples over 56 bars is exactly two samples per bar, so bar 0 is
      // built from levels[0] and levels[1] and nothing else.
      final levels = List<double>.filled(112, 0.1)
        ..[0] = 0.1
        ..[1] = 0.9;
      final bytes = base64Decode(VoicePeaks.encode(levels)!);
      expect(bytes[0], (0.9 * 255).round(),
          reason: 'the mean would be 0.5 -> 128, which flattens speech',);
    });

    test('a note shorter than the bar count stretches across the full width',
        () {
      // Three samples cannot fill 56 bars. Every bar must still carry a level,
      // or a two-second note draws as a stub with forty dead bars after it.
      final bytes = base64Decode(VoicePeaks.encode([0.4, 0.8, 0.6])!);
      expect(bytes.length, VoicePeaks.bars);
      expect(bytes.every((b) => b > 0), isTrue);
    });

    test('silence is null, never a row of zeros', () {
      // The column comment forbids it: zeros claim the microphone heard
      // nothing at all, which is a stronger statement than "no shape stored".
      expect(VoicePeaks.encode(List<double>.filled(200, 0)), isNull);
      expect(VoicePeaks.encode([]), isNull);
    });

    test('the encoded string always fits the column CHECK', () {
      final levels = List<double>.filled(900, 1);
      final encoded = VoicePeaks.encode(levels)!;
      expect(encoded.length, lessThanOrEqualTo(VoicePeaks.maxEncodedLength));
      expect(encoded.length, 76, reason: 'base64 of 56 bytes');
    });

    test('full scale is 255 and out-of-range levels are clamped, not wrapped',
        () {
      final loud = base64Decode(VoicePeaks.encode(List.filled(56, 1))!);
      expect(loud.every((b) => b == 255), isTrue);
      // A dBFS reading above 0 is possible on a clipping mic; it must not wrap
      // round to a quiet bar.
      final over = base64Decode(VoicePeaks.encode(List.filled(56, 4.2))!);
      expect(over.every((b) => b == 255), isTrue);
    });
  });

  group('decode', () {
    test('round-trips what encode produced', () {
      final levels = List<double>.generate(300, (i) => (i % 10) / 10);
      final encoded = VoicePeaks.encode(levels)!;
      expect(VoicePeaks.decode(encoded), base64Decode(encoded));
    });

    test('a shape this build cannot read is null, never a throw', () {
      // The fleet is sideloaded with no update channel, so a row written by a
      // build that encodes differently is permanent, not transitional. A chat
      // screen that throws while building a row is the unacceptable outcome.
      expect(VoicePeaks.decode(null), isNull);
      expect(VoicePeaks.decode(''), isNull);
      expect(VoicePeaks.decode('not base64 at all!!'), isNull);
      expect(VoicePeaks.decode('A'), isNull);
      expect(VoicePeaks.decode('#' * 80), isNull);
    });

    test('refuses a string longer than the column could have held', () {
      expect(VoicePeaks.decode(base64Encode(List.filled(400, 7))), isNull);
    });
  });

  group('the row boundary', () {
    test('a shape from the server reaches the model', () {
      final m = Message.fromJson({
        'id': 'a',
        'sender_id': 'b',
        'created_at': '2026-08-23T10:00:00Z',
        'kind': 'voice',
        'voice_path': 'c/voice_1.m4a',
        'voice_peaks': 'AAECAwQF',
      });
      expect(m.voicePeaks, 'AAECAwQF');
    });

    test('a note from a client that predates the column parses as null', () {
      // The fleet is sideloaded with no update channel, so these keep arriving
      // indefinitely; null must be an ordinary value, not a parse failure.
      final m = Message.fromJson({
        'id': 'a',
        'sender_id': 'b',
        'created_at': '2026-08-23T10:00:00Z',
        'kind': 'voice',
        'voice_path': 'c/voice_1.m4a',
      });
      expect(m.voicePeaks, isNull);
    });

    test('the server echo does not blank a shape the sender already drew', () {
      // reconcileWith adopts the authoritative row. Forgetting the field here
      // is the subtle failure: the waveform appears on send, then vanishes a
      // second later when the postgres echo lands on the sender's own phone.
      final local = Message(
        id: 'a',
        senderId: 'b',
        createdAt: DateTime.utc(2026, 8, 23),
        kind: 'voice',
        voicePeaks: 'AAECAwQF',
      );
      final server = Message(
        id: 'a',
        senderId: 'b',
        createdAt: DateTime.utc(2026, 8, 23),
        kind: 'voice',
        voicePeaks: 'AAECAwQF',
        seq: 12,
      );
      expect(local.reconcileWith(server).voicePeaks, 'AAECAwQF');
      expect(local.copyWith().voicePeaks, 'AAECAwQF');
      expect(local.withDecrypted(null).voicePeaks, 'AAECAwQF');
    });
  });
}
