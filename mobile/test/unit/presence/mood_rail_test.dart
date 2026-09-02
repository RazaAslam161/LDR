import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';

/// The partner's mood, on the instant rail.
///
/// Mood used to travel by the presence row alone: one upsert, one
/// postgres_changes hop, ~750ms–1.2s before the other phone's face changed.
/// The owner's brief was "instantly synchronized, without any second delay",
/// so it now also rides the `screen_presence` broadcast — and every law about
/// how the two rails agree is pinned here, without a socket.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(PresenceService.resetMoodHint);
  tearDown(PresenceService.resetMoodHint);

  final t0 = DateTime.utc(2026, 9, 2, 12);
  final earlier = t0.subtract(const Duration(seconds: 3));
  final later = t0.add(const Duration(seconds: 3));

  Presence row({String? mood, DateTime? at}) =>
      Presence(userId: 'p1', currentMood: mood, moodUpdatedAt: at);

  Profile me() => Profile(
        id: 'me',
        displayName: 'Ali',
        timezone: 'UTC',
        presenceStatus: PresenceStatus.awake,
        createdAt: DateTime.utc(2026),
      );

  group('mergeMood', () {
    test('no hint: the row is the mood', () {
      expect(PresenceService.mergeMood(row(mood: 'calm', at: t0), null), 'calm');
      expect(PresenceService.mergeMood(null, null), isNull);
    });

    test('no row: the hint is the mood', () {
      expect(
        PresenceService.mergeMood(null, (mood: 'angry', at: t0)),
        'angry',
      );
    });

    test('a row STRICTLY newer than the hint wins — a broadcast was missed', () {
      expect(
        PresenceService.mergeMood(
          row(mood: 'joyful', at: later),
          (mood: 'angry', at: t0),
        ),
        'joyful',
      );
    });

    test('an equal or older row loses — the database is still catching up', () {
      expect(
        PresenceService.mergeMood(
          row(mood: 'stale', at: t0),
          (mood: 'angry', at: t0),
        ),
        'angry',
        reason: 'the same instant is the same mood; the hint got there first',
      );
      expect(
        PresenceService.mergeMood(
          row(mood: 'stale', at: earlier),
          (mood: 'angry', at: t0),
        ),
        'angry',
      );
    });

    test('a row with no stamp cannot outrank a hint', () {
      expect(
        PresenceService.mergeMood(row(mood: 'stale'), (mood: 'angry', at: t0)),
        'angry',
      );
    });
  });

  group('applyMoodHint', () {
    test('newer replaces, equal or older is dropped', () {
      PresenceService.applyMoodHint(mood: 'a', at: t0);
      PresenceService.applyMoodHint(mood: 'b', at: earlier);
      expect(PresenceService.moodHint.value?.mood, 'a',
          reason: 'a reordered broadcast must not win',);
      PresenceService.applyMoodHint(mood: 'c', at: t0);
      expect(PresenceService.moodHint.value?.mood, 'a');
      PresenceService.applyMoodHint(mood: 'd', at: later);
      expect(PresenceService.moodHint.value?.mood, 'd');
    });

    test('reset empties it', () {
      PresenceService.applyMoodHint(mood: 'a', at: t0);
      PresenceService.resetMoodHint();
      expect(PresenceService.moodHint.value, isNull);
    });
  });

  group('the row carries the stamp', () {
    test('fromJson parses mood_updated_at as UTC', () {
      final p = Presence.fromJson({
        'user_id': 'p1',
        'current_mood': 'cozy',
        'mood_updated_at': '2026-09-02T12:00:00+00:00',
      });
      expect(p.moodUpdatedAt, t0);
      expect(p.moodUpdatedAt!.isUtc, isTrue);
    });

    test('withLiveness carries it — or the database could never win', () {
      final p = row(mood: 'cozy', at: t0).withLiveness(isOnline: true);
      expect(p.moodUpdatedAt, t0);
      expect(p.currentMood, 'cozy');
    });
  });

  group('instant', () {
    ProviderContainer bench() {
      final c = ProviderContainer(
        overrides: [
          // Null couple: every presence notifier binds on a couple and skips
          // Supabase entirely without one — the pattern all presence tests use.
          currentCoupleProvider.overrideWithValue(null),
          currentProfileProvider.overrideWithValue(me()),
          partnerPresenceProvider.overrideWith(_StubPresence.new),
        ],
      );
      addTearDown(c.dispose);
      // Held, or the autoDispose provider is gone before it is read back.
      c.listen(partnerMoodProvider, (_, __) {});
      return c;
    }

    test('a mood broadcast reaches the provider with NO await', () {
      final c = bench();
      c.read(partnerScreenProvider.notifier).onMoodBroadcast({
        'from': 'p1',
        'mood': 'angry',
        'at': t0.toIso8601String(),
      });
      // No pump, no await, no fake async. Anything deferred on the path —
      // a timer, the 800ms refetch debounce — fails this line.
      expect(c.read(partnerMoodProvider), 'angry');
    });

    test('our own echo is dropped', () {
      final c = bench();
      c.read(partnerScreenProvider.notifier).onMoodBroadcast({
        'from': 'me',
        'mood': 'angry',
        'at': t0.toIso8601String(),
      });
      expect(c.read(partnerMoodProvider), isNull);
    });

    test('a malformed payload is ignored, not applied', () {
      final c = bench();
      final n = c.read(partnerScreenProvider.notifier);
      n.onMoodBroadcast({'from': 'p1', 'mood': 'angry'}); // no `at`
      n.onMoodBroadcast({'from': 'p1', 'at': t0.toIso8601String()}); // no mood
      n.onMoodBroadcast({'from': 'p1', 'mood': '', 'at': t0.toIso8601String()});
      n.onMoodBroadcast({'from': 'p1', 'mood': 'x', 'at': 'not a date'});
      expect(c.read(partnerMoodProvider), isNull);
    });

    test('an older row cannot overwrite the broadcast; a newer one can', () {
      final c = bench();
      c.read(partnerScreenProvider.notifier).onMoodBroadcast({
        'from': 'p1',
        'mood': 'angry',
        'at': t0.toIso8601String(),
      });
      final presence = c.read(partnerPresenceProvider.notifier) as _StubPresence;

      presence.push(row(mood: 'calm', at: earlier));
      expect(c.read(partnerMoodProvider), 'angry',
          reason: 'the database catching up must not undo the socket',);

      presence.push(row(mood: 'joyful', at: later));
      expect(c.read(partnerMoodProvider), 'joyful',
          reason: 'a mood set while the socket was down arrives by the row',);
    });

    test('the database face shows before any broadcast exists', () {
      final c = bench();
      final presence = c.read(partnerPresenceProvider.notifier) as _StubPresence;
      presence.push(row(mood: 'cozy', at: t0));
      expect(c.read(partnerMoodProvider), 'cozy');
    });
  });

  group('source laws', () {
    final badge =
        File('lib/core/widgets/partner_here_badge.dart').readAsStringSync();
    final chat = File('lib/features/chat/chat_screen.dart').readAsStringSync();
    final session =
        File('lib/core/app/session_provider.dart').readAsStringSync();
    final service =
        File('lib/core/services/presence_service.dart').readAsStringSync();

    String stripped(String s) => s.replaceAll(RegExp('//.*'), '');

    test('nothing on the mood path is deferred', () {
      final src = stripped(badge);
      // Anchored on code, not on the doc comment that follows it — comments
      // are stripped above, and the doc for warm() goes with them.
      final handler = src.substring(
        src.indexOf('void onMoodBroadcast('),
        src.indexOf('void warm()'),
      );
      final start = src.indexOf('class PartnerMoodNotifier');
      final notifier = src.substring(start, src.indexOf('\n}', start));
      for (final code in [handler, notifier]) {
        for (final banned in [
          'Timer(',
          'Future.delayed',
          'debounce',
          'milliseconds: 800',
        ]) {
          expect(code.contains(banned), isFalse,
              reason: '"$banned" on the mood path — the second of delay this '
                  'rail exists to remove',);
        }
      }
    });

    test('the broadcast leaves before the database write is awaited', () {
      final src = stripped(chat);
      final start = src.indexOf('Future<void> _setMyMood()');
      final body = src.substring(start, src.indexOf('\n  }', start));
      final bcast = body.indexOf('announceMood(');
      final db = body.indexOf('await PresenceService.setMood(');
      expect(bcast, greaterThan(-1), reason: 'the broadcast is never sent');
      expect(db, greaterThan(-1), reason: 'the durable write is gone');
      expect(bcast, lessThan(db),
          reason: "the partner's face must not wait on this phone's REST "
              'round trip',);
    });

    test('an identity switch drops the hint', () {
      expect(stripped(session).contains('resetMoodHint()'), isTrue,
          reason: 'a hint ordered by the previous partner\'s clock would '
              'swallow the next partner\'s first moods',);
    });

    test('the merge consults no second clock', () {
      final src = stripped(service);
      final start = src.indexOf('static String? mergeMood(');
      final body = src.substring(start, src.indexOf('\n  }', start));
      expect(body.contains('ServerClock'), isFalse,
          reason: 'both stamps are the sender\'s own clock; reconciling them '
              'against ours would order them wrongly by exactly the offset',);
    });
  });
}

class _StubPresence extends PartnerPresenceNotifier {
  _StubPresence(super.ref);

  void push(Presence? p) => state = p;
}
