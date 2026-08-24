import 'dart:convert';
import 'dart:typed_data';

/// The shape of a voice note, in the form the database already defines.
///
/// `messages.voice_peaks` reached production on 2026-08-20 carrying its own
/// contract in its column comment: base64 of one byte per bar, 56 bars,
/// sampled at 100ms and reduced by loudest-in-bucket. The Dart half of that
/// change was lost with the disk that held the working tree, and the column sat
/// in production with nothing writing it. This is that half, written back
/// against the column rather than beside it — a second encoding would leave
/// every note the other build sent undrawable, in both directions, forever.
class VoicePeaks {
  VoicePeaks._();

  /// One byte per bar, and the bar count is fixed rather than chosen per note.
  ///
  /// The column's CHECK bounds the encoded string at 256 characters; base64 of
  /// 56 bytes is 76 of them, so the constraint has room to spare and no note
  /// can ever be refused for its shape. Changing this number is a conversation
  /// with the database, not a layout tweak.
  static const int bars = 56;

  /// The widest string the column will accept, from
  /// `messages_voice_peaks_len`. A violation does not drop the column — it
  /// fails the whole INSERT and loses the voice note — so the encoder refuses
  /// to emit one rather than letting the send throw.
  static const int maxEncodedLength = 256;

  /// Recorder levels in 0..1, one per sample, to the column's string.
  ///
  /// Null, not a string, when there is nothing honest to draw. The column
  /// comment is explicit that a row of zeros is forbidden: it would assert the
  /// microphone heard pure silence for the entire recording, which is a
  /// stronger and usually falser claim than "this note carries no shape".
  static String? encode(List<double> levels) {
    if (levels.isEmpty) return null;

    final bytes = Uint8List(bars);
    var loudest = 0;
    for (var i = 0; i < bars; i++) {
      // Integer bucket bounds, so the last bucket ends exactly on the last
      // sample however the count divides — a rounded stride drops or repeats
      // the tail depending on the remainder.
      final lo = (i * levels.length) ~/ bars;
      var hi = ((i + 1) * levels.length) ~/ bars;
      // A note shorter than the bar count leaves buckets empty. Each empty bar
      // reads the sample it starts on, which stretches a two-second note across
      // the full width instead of drawing it as a stub followed by forty dead
      // bars.
      if (hi <= lo) hi = lo + 1;

      var peak = 0.0;
      for (var j = lo; j < hi && j < levels.length; j++) {
        // Loudest in the bucket, not the mean. An average flattens speech into
        // a smooth ridge; the peaks are what make a waveform recognisable as
        // the sentence that was said.
        if (levels[j] > peak) peak = levels[j];
      }

      final level = (peak.clamp(0.0, 1.0) * 255).round();
      bytes[i] = level;
      if (level > loudest) loudest = level;
    }

    if (loudest == 0) return null;

    final encoded = base64Encode(bytes);
    // Unreachable while [bars] is 56, and deliberately still here: the failure
    // it guards is not a wrong drawing but a lost recording, and the next
    // person to change the bar count will not be reading this constraint.
    if (encoded.length > maxEncodedLength) return null;
    return encoded;
  }

  /// The column's string back to one byte per bar, or null for anything this
  /// build cannot draw.
  ///
  /// Every failure is a null rather than a throw, and that is a decision about
  /// the fleet rather than about tidiness. The value arrives from a row written
  /// by some other build of this app; sideloaded handsets have no update
  /// channel, so a client that writes a shape this one does not understand is a
  /// permanent possibility, not a transitional one. A bubble that falls back to
  /// its own pattern is a fine outcome. A chat screen that throws while
  /// building a row is not.
  static Uint8List? decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    if (encoded.length > maxEncodedLength) return null;
    try {
      final bytes = base64Decode(encoded);
      return bytes.isEmpty ? null : bytes;
    } on FormatException {
      // Not swallowed: null IS the handled outcome, and the bubble draws its
      // fallback pattern from the message id. There is nothing a user could do
      // with a report that another build wrote a shape this one cannot read.
      return null;
    }
  }

  /// The shape to draw for a note that carries none.
  ///
  /// The column comment names this fallback: null peaks means "draw a
  /// per-message pattern derived from the message id". Derived, not random and
  /// not constant — the bubble that today generates its bars from the BAR's
  /// index draws every note in the conversation identically, which is what made
  /// a two-second note and a two-minute note indistinguishable. Seeded from the
  /// id, a note at least looks like itself and looks the same on both phones.
  ///
  /// This is decoration and says nothing about the audio. It is deliberately
  /// mid-range and lumpy rather than flat, so it reads as "shape unknown"
  /// rather than as a recording of silence.
  static Uint8List patternFor(String messageId) {
    // FNV-1a. Chosen because it is four lines and stable across platforms and
    // releases — Object.hashCode is neither, and the two phones must draw the
    // same note the same way.
    var hash = 2166136261;
    for (final unit in messageId.codeUnits) {
      hash = (hash ^ unit) * 16777619 & 0xFFFFFFFF;
    }
    final out = Uint8List(bars);
    for (var i = 0; i < bars; i++) {
      hash = (hash ^ (hash >> 13)) * 16777619 & 0xFFFFFFFF;
      // 70..225: never the floor, so no bar vanishes, and never full scale, so
      // a guessed shape never looks louder than a measured one.
      out[i] = 70 + (hash >> 7) % 156;
    }
    return out;
  }
}
