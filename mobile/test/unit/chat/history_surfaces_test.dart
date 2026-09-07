import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Three surfaces that were live-only, each losing something the rows still
/// held.
///
/// The gallery seeded on 500 and could not reach past it. The daily question
/// showed today's and nothing else, so yesterday's question and both answers
/// to it left the app when the date rolled over. Care reminders showed the
/// newest 50 with no way behind them and no age on any of them — and the
/// retention sweep deletes at 30 days without ever saying so.
String _code(String s) =>
    s.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

void main() {
  group('the gallery can reach its oldest picture', () {
    final repo =
        File('lib/features/gallery/gallery_repository.dart').readAsStringSync();
    final screen =
        File('lib/features/gallery/gallery_screen.dart').readAsStringSync();

    test('the window pages on the cursor, not an offset', () {
      final w = repo.substring(repo.indexOf('class GalleryWindow'));
      expect(w, contains('Future<void> more() async {'));
      expect(w, contains('fetchPage(coupleId, before: before)'));
      expect(w, contains('DateTime? get _cursor'));
    });

    test('it speaks SharedMediaWindow s vocabulary', () {
      final w = repo.substring(repo.indexOf('class GalleryWindow'));
      for (final f in const ['bool busy', 'bool atEnd', 'Object? failed']) {
        expect(w, contains(f), reason: f);
      }
      expect(w, contains('page.length < GalleryRepository.pageSize'));
    });

    test('an older page never overwrites a live delta', () {
      // A realtime delta that landed while the page was on the wire is NEWER
      // than the row the page carries — including a deletion.
      final w = _code(repo.substring(repo.indexOf('class GalleryWindow')));
      expect(w, contains('if (_byId.containsKey(i.id)) continue;'));
    });

    test('one map, so a deleted picture cannot come back through the page', () {
      final w = repo.substring(repo.indexOf('class GalleryWindow'));
      expect(w, contains('final Map<String, GalleryItem> _byId'));
      expect(w, contains('_apply(PostgresChangePayload p)'),
          reason: 'the deltas patch the same map the pages merge into',);
    });

    test('the screen asks before the finger arrives, and cleans up', () {
      expect(screen, contains('_grid.addListener(_onGridScroll)'));
      expect(screen, contains('extentAfter > 600'));
      expect(screen, contains('_window?.dispose()'));
      expect(screen, contains('_grid.dispose()'));
    });
  });

  group('the daily question has a yesterday', () {
    final repo = File('lib/features/daily_prompt/daily_prompt_repository.dart')
        .readAsStringSync();
    final screen =
        File('lib/features/daily_prompt/daily_prompt_history_screen.dart')
            .readAsStringSync();

    test('history pages on the key the table already has', () {
      expect(repo, contains('static Future<List<DailyPrompt>> history('));
      expect(repo, contains("lt('scheduled_date', before)"));
      expect(repo, contains("order('scheduled_date', ascending: false)"));
    });

    test('a page of answers is ONE round trip', () {
      // Per prompt would be thirty selects behind one screen, on mobile data.
      expect(repo, contains('responsesForMany('));
      expect(repo, contains("inFilter('prompt_id', promptIds)"));
      expect(repo, contains('if (promptIds.isEmpty) return const {};'));
    });

    test('the reveal rule is the same one the day card keeps', () {
      // A history that showed the partner's answer to a question you never
      // answered would be a way to read them without ever writing back.
      expect(screen, contains('final both = mine != null && theirs != null;'));
      expect(screen, contains('never answered'));
    });

    test('it is reachable, routed, and known to the presence observer', () {
      final router = File('lib/core/app/router.dart').readAsStringSync();
      expect(router, contains("path: '/app/prompt/history'"));
      final day = File('lib/features/daily_prompt/daily_prompt_screen.dart')
          .readAsStringSync();
      expect(day, contains("context.push('/app/prompt/history')"),
          reason: 'a screen reachable from nowhere is not a feature',);
      final obs = File('test/unit/presence/presence_route_observer_test.dart')
          .readAsStringSync();
      expect(obs, contains("'/app/prompt/history'"));
    });
  });

  group('care reminders say when, and say when they end', () {
    final repo =
        File('lib/features/care/care_repository.dart').readAsStringSync();
    final screen =
        File('lib/features/care/care_screen.dart').readAsStringSync();

    test('the list pages on created_at', () {
      expect(repo, contains('static const pageSize = 50;'));
      expect(repo, contains("q.lt('created_at', before.toUtc()"));
    });

    test('every tile carries its age', () {
      expect(screen, contains('static String _age(DateTime at)'));
      expect(screen, contains(r"' · ${_age(n.createdAt)}'"));
    });

    test('the end of the list explains itself', () {
      // The retention sweep (20260601005000) deletes at 30 days and the screen
      // never said so — a reminder was simply not there any more, which reads
      // as the app having lost it.
      expect(screen, contains('Reminders are kept for 30 days.'));
      expect(screen, contains('Show older'));
      final tail = screen.substring(screen.indexOf('Widget _tail()'));
      expect(tail.substring(0, 900), contains('_moreNudges'));
    });

    test('a failed page keeps the page already on screen', () {
      final more = _code(screen).substring(_code(screen).indexOf('Future<void> _loadMore()'));
      expect(more.substring(0, 900), contains('_moreNudges = false'));
      expect(more.substring(0, 900), isNot(contains('_nudges = const []')));
    });
  });
}
