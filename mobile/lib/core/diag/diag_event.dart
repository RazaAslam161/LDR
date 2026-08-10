import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Which mechanism an event belongs to. Kept small on purpose — a trace with
/// forty categories is one nobody filters.
enum DiagArea { call, receipt, presence, app }

/// One observation, from one device, at one instant.
///
/// The shape is dictated by what went wrong before it existed. Three mechanisms
/// have been "fixed" repeatedly by changing code and guessing, because the only
/// evidence available was `debugPrint` — which reaches logcat, which reaches a
/// cable, which reaches exactly one of the two phones involved. Every one of
/// these failures is a failure BETWEEN two devices, so a trace that only ever
/// describes one of them cannot decide anything.
///
/// Hence the three fields that look redundant and are not:
///   [at]        device time already corrected by ServerClock, so two devices
///               share one timeline to the precision of the clock sync.
///   [seq]       monotonic within a session, so events inside the same
///               millisecond keep their order (ICE fires bursts).
///   [corr]      joins this device's view of an interaction to the partner's.
///               Without it you have two traces; with it you have one.
@immutable
class DiagEvent {
  const DiagEvent({
    required this.seq,
    required this.at,
    required this.area,
    required this.name,
    this.corr,
    this.fields = const {},
  });

  final int seq;
  final DateTime at;
  final DiagArea area;

  /// snake_case, stable. These get grepped; renaming one loses history.
  final String name;

  /// Call id, message id, couple id — whatever joins the two devices' traces
  /// for this interaction.
  final String? corr;

  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => {
        'seq': seq,
        'at': at.toIso8601String(),
        'area': area.name,
        'name': name,
        if (corr != null) 'corr': corr,
        if (fields.isNotEmpty) 'fields': fields,
      };

  /// One line, appended to disk. NDJSON because the file is read after a crash:
  /// a truncated last line costs one event, not the whole trace.
  String toNdjson() => jsonEncode(toJson());

  /// Human form, for the in-app viewer and for pasting into a bug report.
  String get line {
    final f = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    final t = at.toIso8601String().substring(11, 23);
    return '$t ${area.name}.$name${corr == null ? '' : ' [$corr]'}'
        '${f.isEmpty ? '' : ' $f'}';
  }
}

/// Keeps content out of the trace.
///
/// This app carries a couple's private messages, intimate media and live
/// location. A diagnostic that uploads any of that is a worse bug than the one
/// it was added to find, and the failure mode is quiet: someone adds
/// `'body': m.text` to an existing event during a late-night debugging session
/// and it ships.
///
/// So the sink does not trust its callers. Values are scalars only, and a
/// string that looks like content — long, a URL, a token, an address, an SDP
/// blob — is replaced rather than truncated. Truncation is the wrong answer
/// here: the first 96 characters of a private message are still a private
/// message.
///
/// Call sites are additionally checked by test/unit/diag_privacy_test.dart, so
/// a field that is sensitive but short (a display name) is caught too.
///
/// The rule is an ALLOWLIST, arrived at by watching a denylist fail. Rejecting
/// strings that look like content passed "I miss you so much it actually hurts
/// sometimes" — 55 characters, under any sane length cap, and content by any
/// definition. Every pattern added afterwards had the same hole one example
/// over.
///
/// So the question is inverted. A trace value is a TOKEN: one word from a
/// restricted alphabet — a state name, an enum, a UUID, an error class, a mime
/// type. Prose has spaces and prose is what leaks, so a space is disqualifying
/// on its own and nothing has to recognise the sentence.
class DiagRedact {
  DiagRedact._();

  static const redacted = '<redacted>';

  /// Comfortably fits 'RTCPeerConnectionStateDisconnected' and a UUID.
  static const maxStringLength = 64;

  /// The alphabet a legitimate trace token is drawn from. Notably absent: space
  /// (prose), '=' (SDP attributes), '@' (email), and everything non-ASCII.
  static final _token = RegExp(r'^[A-Za-z0-9_.:/-]+$');

  static final _url = RegExp(r'https?:|[a-z0-9-]+\.(com|co|net|org|io)\b',
      caseSensitive: false,);
  static final _jwt = RegExp('^ey[A-Za-z0-9_-]{8,}');
  static final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  /// A storage object, which is media. One slash is a mime type ('video/VP8')
  /// and is kept, because the codec is real evidence in a call trace.
  static final _objectPath = RegExp('/.*/');
  static final _mediaFile =
      RegExp(r'\.(jpg|jpeg|png|webp|gif|heic|mp4|m4a|aac|opus|ogg)$',
          caseSensitive: false,);

  static Object? value(Object? v) {
    if (v == null || v is num || v is bool) return v;
    if (v is Duration) return v.inMilliseconds;
    if (v is! String) return redacted; // no maps, no lists — keep events flat
    if (v.isEmpty) return v;
    if (v.length > maxStringLength) return redacted;
    if (!_token.hasMatch(v)) return redacted;
    if (_url.hasMatch(v) ||
        _jwt.hasMatch(v) ||
        _ipv4.hasMatch(v) ||
        _objectPath.hasMatch(v) ||
        _mediaFile.hasMatch(v)) {
      return redacted;
    }
    return v;
  }

  static Map<String, Object?> fields(Map<String, Object?> f) =>
      {for (final e in f.entries) e.key: value(e.value)};
}
