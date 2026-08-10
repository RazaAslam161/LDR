import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/diag/diag_event.dart';

/// The trace must never carry content.
///
/// This app holds a couple's private messages, intimate media and live
/// location, and the diagnostics upload leaves the device. A field that leaks
/// content is a worse bug than any of the three it was added to find, and it
/// would arrive the same quiet way every time: someone adds `'body': m.text` to
/// an existing event at 2am to answer one question, and it ships.
///
/// Two layers, because either alone is insufficient. [DiagRedact] catches
/// anything that LOOKS like content at runtime, including from code this test
/// has never seen. The call-site scan catches what redaction cannot — a display
/// name is short, plain and indistinguishable from an enum.
void main() {
  group('DiagRedact', () {
    test('passes the things a trace is actually made of', () {
      for (final v in <Object?>[
        0,
        -1,
        42,
        1.5,
        true,
        false,
        null,
        'connected',
        'relay',
        'CHANNEL_ERROR',
        'PostgrestException',
        '3f8a1c2e-1111-4222-8333-444455556666',
        'RTCPeerConnectionStateDisconnected',
        // The negotiated codec is real evidence in a call trace, and one slash
        // is what a mime type looks like.
        'video/VP8',
      ]) {
        expect(DiagRedact.value(v), v, reason: '$v should survive redaction');
      }
    });

    test('a SHORT private message is still redacted', () {
      // The case that broke the previous denylist design. 55 characters — under
      // any length cap anyone would pick, and content by any definition. Prose
      // has spaces; that is the whole discriminator.
      const short = 'I miss you so much it actually hurts sometimes, honestly';
      expect(short.length, lessThan(DiagRedact.maxStringLength));
      expect(DiagRedact.value(short), DiagRedact.redacted);
    });

    test('Duration becomes milliseconds', () {
      expect(DiagRedact.value(const Duration(seconds: 2)), 2000);
    });

    test('redacts message-shaped text', () {
      // Any real sentence exceeds the cap. Truncation is deliberately not used:
      // the first 64 characters of a private message are still a private
      // message.
      const msg = 'hey love, I was thinking about you all afternoon and I '
          'cannot wait until friday';
      expect(DiagRedact.value(msg), DiagRedact.redacted);
    });

    test('redacts media URLs and storage paths', () {
      for (final v in [
        'https://sopictusdonlvuezmfep.supabase.co/storage/v1/o/chat/x.jpg',
        // A bare object path carries no host and no scheme, so nothing about it
        // looks like a URL — it is media all the same.
        'chat-media/9f1a/selfie.jpg',
        'voice/2026/08/note.m4a',
        'IMG_20260809.jpg',
      ]) {
        expect(DiagRedact.value(v), DiagRedact.redacted, reason: v);
      }
    });

    test('redacts email, tokens, IPs and SDP', () {
      for (final v in [
        'someone@example.com',
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9',
        '192.168.1.14',
        'candidate:842163049 1 udp 1686052607 typ srflx',
        'a=ice-ufrag:F7gI',
      ]) {
        expect(DiagRedact.value(v), DiagRedact.redacted, reason: v);
      }
    });

    test('the candidate TYPE alone is still allowed', () {
      // This is the single most valuable field in a call trace and it carries
      // no address. Redacting the candidate line must not take it with it.
      expect(DiagRedact.value('srflx'), 'srflx');
      expect(DiagRedact.value('host'), 'host');
    });

    test('maps and lists are refused rather than serialised', () {
      // A nested map is how content sneaks in wholesale — `'row': payload`.
      expect(DiagRedact.value({'text': 'hello'}), DiagRedact.redacted);
      expect(DiagRedact.value(['a', 'b']), DiagRedact.redacted);
    });

    test('redacts every value in a field map, leaving keys intact', () {
      final out = DiagRedact.fields({
        'state': 'connected',
        'peer_note': 'I miss you so much it actually hurts sometimes, honestly',
      });
      expect(out['state'], 'connected');
      expect(out['peer_note'], DiagRedact.redacted);
      expect(out.keys, containsAll(['state', 'peer_note']));
    });
  });

  test('no call site passes a sensitive accessor into a trace field', () {
    // Redaction cannot catch a short, plain, sensitive string — a display name
    // looks exactly like an enum. This reads the actual call sites instead.
    //
    // `.length` and null-checks are allowed on purpose: `sdp_len` and
    // `has_relay` are the safe derived forms, and forbidding the accessor
    // outright would push people to compute the same thing less legibly.
    const sensitive = [
      '.text',
      '.body',
      '.content',
      '.caption',
      '.url',
      '.path',
      '.displayName',
      '.email',
      '.candidate',
      '.sdp',
      '.latitude',
      '.longitude',
      '.token',
    ];
    const safeSuffixes = [
      '.length',
      '?.length',
      '.isEmpty',
      '.isNotEmpty',
      '!= null',
      '== null',
    ];

    final offenders = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      if (!src.contains('Diag.')) continue;
      final lines = src.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Field maps span lines, so scan the whole body of a Diag call rather
        // than the single line that names it.
        if (!_insideDiagCall(lines, i)) continue;
        for (final s in sensitive) {
          final at = line.indexOf(s);
          if (at < 0) continue;
          final rest = line.substring(at + s.length);
          if (safeSuffixes.any(rest.trimLeft().startsWith)) continue;
          offenders.add('${f.uri.pathSegments.last}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'a trace field may not carry content — use the derived form '
            '(sdp_len, has_relay, name_set): ${offenders.join(' | ')}');
  });
}

/// True when [i] falls inside a `Diag.record(` / `Diag.span(` argument list.
/// Crude brace counting is enough: these calls are short and never nested.
bool _insideDiagCall(List<String> lines, int i) {
  for (var j = i; j >= 0 && j > i - 12; j--) {
    if (RegExp(r'Diag\.(record|span)\(').hasMatch(lines[j])) {
      var depth = 0;
      for (var k = j; k <= i; k++) {
        depth += '('.allMatches(lines[k]).length;
        depth -= ')'.allMatches(lines[k]).length;
      }
      return depth > 0 || j == i;
    }
  }
  return false;
}
