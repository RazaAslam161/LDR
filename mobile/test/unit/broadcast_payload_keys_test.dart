import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Supabase's realtime_client MUTATES the payload map you hand it.
///
/// `RealtimeChannel.send()` (realtime_client 2.8.0, realtime_channel.dart:628)
/// does, before anything is serialised:
///
///     payload['type'] = type.toType();   // -> 'broadcast'
///     if (event != null) payload['event'] = event;
///
/// So 'type' and 'event' are the transport's, not yours. A payload key called
/// either one is silently overwritten on the sending device — no error, no
/// warning, nothing in a log, and the receiver simply gets the wrong value.
///
/// This cost every audio and video call in the app: the signalling kind
/// travelled under 'type', arrived as the literal string 'broadcast', matched
/// no case in the switch, and every offer, answer and ICE candidate was
/// dropped. It also quietly replaced the chosen touch-map effect with the
/// fallback for every user.
///
/// Nothing else can catch this. It compiles, it type-checks, it runs, and the
/// analyzer has no opinion — so the rule is enforced here, against the source.
void main() {
  const reserved = ['type', 'event'];

  test('no broadcast payload uses a key realtime_client will overwrite', () {
    final offenders = <String>[];

    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = file.readAsStringSync();
      var from = 0;
      while (true) {
        final call = src.indexOf('sendBroadcastMessage', from);
        if (call < 0) break;
        from = call + 1;

        // The payload literal for this call: from 'payload:' to the brace that
        // closes it. Good enough to read one argument, and it only has to
        // understand the shape this codebase actually writes.
        final payloadAt = src.indexOf('payload:', call);
        if (payloadAt < 0) continue;
        final open = src.indexOf('{', payloadAt);
        if (open < 0) continue;
        var depth = 0;
        var close = open;
        for (var i = open; i < src.length; i++) {
          if (src[i] == '{') depth++;
          if (src[i] == '}') {
            depth--;
            if (depth == 0) {
              close = i;
              break;
            }
          }
        }
        final payload = src.substring(open, close + 1);

        for (final key in reserved) {
          if (payload.contains("'$key':") || payload.contains('"$key":')) {
            final line = '\n'.allMatches(src.substring(0, open)).length + 1;
            offenders.add('${file.path}:$line uses reserved key "$key"');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'realtime_client overwrites these keys before sending, so the '
          'value never arrives:\n${offenders.join('\n')}\n'
          'Rename the key — "kind", "effect", "action" all work.',
    );
  });
}
