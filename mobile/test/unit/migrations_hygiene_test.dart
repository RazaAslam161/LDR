import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Stage 0: the database must be reproducible from the repo.
///
/// Before this, 42 loose .sql files were pasted into the dashboard by hand in
/// an order that lived only in header comments. Columns the client writes
/// existed in no file at all, and a migration reported "Success" while three of
/// its six protections were silent no-ops. These assertions are cheap and catch
/// the specific ways that happened.
void main() {
  final root = Directory('../supabase');
  final migrations = Directory('../supabase/migrations');

  List<File> sqlIn(Directory d) => d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('the migrations directory exists and is the only place DDL lives', () {
    expect(migrations.existsSync(), isTrue);
    // A stray .sql at the top level is a migration nobody will replay.
    final loose = sqlIn(root);
    expect(loose, isEmpty,
        reason: 'DDL belongs in migrations/, one-off queries in diagnostics/: '
            '${loose.map((f) => f.uri.pathSegments.last).join(', ')}');
  });

  test('every migration is prefixed with a 14-digit ordering key', () {
    // Ordering is the filename. A file without one replays in an
    // unpredictable position relative to its dependencies.
    final bad = sqlIn(migrations)
        .map((f) => f.uri.pathSegments.last)
        .where((n) => !RegExp(r'^\d{14}_[a-z0-9_]+\.sql$').hasMatch(n))
        .toList();
    expect(bad, isEmpty, reason: 'not a valid migration name: $bad');
  });

  test('ordering keys are unique', () {
    final keys = sqlIn(migrations)
        .map((f) => f.uri.pathSegments.last.split('_').first)
        .toList();
    expect(keys.length, keys.toSet().length,
        reason: 'two migrations sharing a key replay in arbitrary order');
  });

  test('config.toml is committed', () {
    // Without it there is no local stack, so nothing can be replayed from
    // empty and no migration can be proven before it reaches production.
    expect(File('../supabase/config.toml').existsSync(), isTrue);
  });

  test('the auth redirect scheme is configured, not left at localhost', () {
    // Supabase defaults site_url to http://localhost:3000. Every confirmation
    // and password-reset mail then opens "localhost refused to connect" on the
    // user's phone — which is every new signup.
    final cfg = File('../supabase/config.toml').readAsStringSync();
    expect(cfg, contains('tethered://auth-callback'));
    expect(cfg.contains('localhost:3000'), isFalse);
  });

  group('dependency order is preserved by the ordering keys', () {
    String keyOf(String needle) {
      final f = sqlIn(migrations).firstWhere(
          (f) => f.uri.pathSegments.last.contains(needle),
          orElse: () => throw StateError('no migration matching $needle'));
      return f.uri.pathSegments.last.split('_').first;
    }

    test('schema comes first', () {
      final first = sqlIn(migrations).first.uri.pathSegments.last;
      expect(first, contains('schema'));
    });

    test('presence_server_time precedes newuser_fixes', () {
      // newuser_fixes redefines presence_stamp_server_time. Replayed the other
      // way round, the older definition wins and the leave_couple privacy wipe
      // is silently overwritten again.
      expect(keyOf('presence_server_time').compareTo(keyOf('newuser_fixes')),
          lessThan(0));
    });

    test('hardening precedes account_deletion', () {
      expect(keyOf('hardening_2026_08').compareTo(keyOf('account_deletion')),
          lessThan(0));
    });

    test('settings_and_delete precedes chat_media_cleanup', () {
      expect(
          keyOf('settings_and_delete').compareTo(keyOf('chat_media_cleanup')),
          lessThan(0));
    });

    test('intimacy_additions precedes intimacy_tables', () {
      expect(keyOf('intimacy_additions').compareTo(keyOf('intimacy_tables')),
          lessThan(0));
    });
  });

  test('every column the client writes to profiles exists in a migration', () {
    // The exact failure that trapped every new user at /role-setup: the client
    // wrote profiles.gender and profiles.gender_set, and no file created
    // either. A clean database therefore had no route past onboarding.
    final all = sqlIn(migrations).map((f) => f.readAsStringSync()).join('\n');
    for (final col in ['gender', 'gender_set', 'fcm_token', 'status_message']) {
      expect(all, contains(col),
          reason: 'profiles.$col is written by the client but created nowhere');
    }
  });

  test('a column-level revoke is never used alone on a granted table', () {
    // A column-level REVOKE cannot narrow a TABLE-level grant — Postgres
    // ignores it and the statement still reports success. Three protections
    // shipped as silent no-ops this way. The correct form revokes the table
    // grant and re-grants the columns that stay writable.
    final all = sqlIn(migrations).map((f) => f.readAsStringSync()).join('\n');
    final columnRevokes =
        RegExp(r'revoke\s+(update|select)\s*\(', caseSensitive: false)
            .allMatches(all)
            .length;
    final tableRevokes =
        RegExp(r'revoke\s+(update|select)\s+on\s', caseSensitive: false)
            .allMatches(all)
            .length;
    expect(tableRevokes, greaterThan(0),
        reason: 'column revokes present ($columnRevokes) with no table-level '
            'revoke to narrow — the column form alone is a no-op');
  });
}
