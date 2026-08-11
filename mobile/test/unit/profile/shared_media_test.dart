import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/profile/shared_media_repository.dart';

/// The partner's profile draws three shelves out of the conversation. Every way
/// it can go wrong is invisible on a conversation that fits in one page, which
/// is the only kind either test phone has ever had.
void main() {
  final migration = File(
      '../supabase/migrations/20260601005500_shared_media_index.sql',)
      .readAsStringSync();
  final repo =
      File('lib/features/profile/shared_media_repository.dart').readAsStringSync();

  group('the shelves the client asks for are the ones Postgres computes', () {
    test('every enum name is a value the media_class expression can produce',
        () {
      // The filter is `.eq('media_class', kind.name)`. Rename either side alone
      // and the tab is not broken, it is EMPTY — a shelf that silently has
      // nothing on it looks exactly like a couple who never sent anything.
      for (final kind in SharedMediaKind.values) {
        expect(migration, contains("then '${kind.name}'"),
            reason: 'nothing in media_class ever evaluates to ${kind.name}',);
      }
    });

    test('the expression produces nothing the client has no shelf for', () {
      final produced = RegExp(r"then '(\w+)'")
          .allMatches(migration)
          .map((m) => m[1]!)
          .toSet();
      expect(produced, SharedMediaKind.values.map((k) => k.name).toSet(),
          reason: 'a fourth class would be indexed and never displayed',);
    });
  });

  group('the link test is spelled the same in both languages', () {
    // media_class decides which rows the Links shelf can EVER see; firstUrl
    // decides what each one renders as. A row the SQL admits and the regex
    // finds no URL in is a blank list item; a row the regex would have found a
    // URL in but the SQL excluded can never be paged back.
    bool sqlSaysLink(String body) {
      final b = body.toLowerCase();
      return b.contains('http://') || b.contains('https://');
    }

    test('the migration still spells it the way this test models it', () {
      // Without this the two implementations below can drift apart and the
      // comparison keeps passing against a predicate nobody uses.
      expect(migration,
          contains("body ilike '%http://%' or body ilike '%https://%'"),);
    });

    test('SQL and the regex agree on every body worth arguing about', () {
      const corpus = [
        'https://example.com/a',
        'http://example.com',
        'Look at this https://example.com/a and this http://b.io',
        'HTTPS://EXAMPLE.COM',
        'Https://Example.com',
        // The one that made the regex `\S*` rather than `\S+`.
        'http://',
        'no link here at all',
        'httpsomething',
        'ftp://example.com',
        'say http to me',
        '',
      ];
      for (final body in corpus) {
        expect(SharedMediaRepository.firstUrl(body) != null, sqlSaysLink(body),
            reason: 'disagreement on: "$body"',);
      }
    });

    test('the URL it extracts is the URL, not the sentence around it', () {
      expect(SharedMediaRepository.firstUrl('look at https://example.com/a now'),
          'https://example.com/a',);
      expect(SharedMediaRepository.firstUrl(null), isNull);
    });
  });

  group('the query cannot degrade into a full scan', () {
    test('the index leads with couple, then class, then seq', () {
      // Any other column order and the class filter stops being an index
      // condition: it becomes a Filter applied after the scan, and filling one
      // 30-tile grid reads every message the couple ever sent. Measured on
      // 40,000 seeded rows: 14,720 rows discarded per page against 0.
      expect(
          migration,
          contains('on public.messages (couple_id, media_class, seq desc)'),);
      expect(migration, contains('where media_class is not null'),
          reason: 'a full index over text messages is most of the table',);
    });

    test('paging is a cursor on seq, never an offset', () {
      // OFFSET 3000 makes the server walk 3000 rows to throw them away, and it
      // shifts under any message that arrives while the grid is open — so a
      // page boundary either repeats a photo or skips one.
      expect(repo, contains(".lt('seq', beforeSeq)"));
      expect(repo, contains(".order('seq', ascending: false)"));
      expect(repo.contains('.range('), isFalse,
          reason: 'range() is OFFSET/LIMIT by another name',);
    });

    test('every page is bounded', () {
      expect(repo, contains('.limit(pageSize)'));
      expect(SharedMediaRepository.pageSize, lessThanOrEqualTo(50));
    });

    test('one signing request per page, not one per tile', () {
      // Thirty tiles each signing for themselves is thirty round trips between
      // the tap and the first thumbnail.
      expect(repo, contains('ChatRepository.warmMedia'));
    });
  });

  group('a deleted message stays deleted', () {
    test('deleted-for-everyone rows are excluded by the query', () {
      // Their storage object is already gone, so the tile would be a permanent
      // grey square — and the row is still in the index because media_class
      // does not care about deletion.
      expect(repo, contains(".eq('deleted_for_everyone', false)"));
    });

    test('a message hidden for me is hidden here too', () {
      // "Delete for me" removed it from the conversation. A grid that shows it
      // anyway is the message coming back through a side door.
      expect(repo, contains(".not('deleted_by', 'cs', [uid])"));
    });
  });

  group('the screen says what is true', () {
    final screen = File('lib/features/profile/partner_profile_screen.dart')
        .readAsStringSync();

    test('a failed load is not drawn as an empty shelf', () {
      // "No photos or videos yet." on a couple with four hundred of them,
      // because the request timed out, is the app inventing their history.
      expect(screen, contains('_failed'));
      expect(screen, contains('Try again'));
    });

    test('the tabs and the shelves are built from the same list', () {
      // A hardcoded ['Media','Documents','Links'] beside a loop over the enum
      // is one reorder away from Documents drawing the photo grid.
      expect(screen, contains('Tab(text: kind.tabLabel)'));
      expect(screen.contains("Tab(text: 'Media')"), isFalse);
    });

    test('presence is the freshness-gated getter, not the stored flag', () {
      // is_online is never written false by an app that was force-killed, which
      // is how Home shows partners as Online hours after they put the phone
      // down. This screen must not repeat it.
      expect(screen, contains('isTrulyOnline'));
      expect(RegExp(r'\.isOnline\b').hasMatch(screen), isFalse);
    });
  });

  test('the screen takes no couple or partner id from its caller', () {
    // Device-scoped leakage is the recurring failure in this app: an FCM token
    // that outlived a sign-out, a cached couple id that outlived a re-pair. A
    // route argument naming a couple is the same shape of mistake, so the
    // screen reads the session and nothing else.
    final screen =
        File('lib/features/profile/partner_profile_screen.dart').readAsStringSync();
    final router = File('lib/core/app/router.dart').readAsStringSync();
    expect(router, contains("path: '/app/partner'"));
    expect(router, contains('const PartnerProfileScreen()'),
        reason: 'the route must not be able to carry an id',);
    expect(screen, contains('ref.watch(sessionProvider)'));
  });
}
