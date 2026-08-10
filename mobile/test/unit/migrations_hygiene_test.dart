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

  test('dollar-quoted bodies are never nested with the same tag', () {
    // Found by the first staging replay, in two migrations that had been in
    // the repo for weeks and could NEVER have executed: a cron job body quoted
    // with a bare $$ inside a `do $$` block terminates the outer block —
    // "syntax error at or near delete". Nested quoting needs distinct tags.
    for (final f in sqlIn(migrations)) {
      final src = f.readAsStringSync();
      for (final m in RegExp(r'do\s+\$\$(.*?)end\s*\$\$',
              dotAll: true, caseSensitive: false)
          .allMatches(src)) {
        expect(RegExp(r'\$\$[^$]*(delete|update|insert|select)',
                caseSensitive: false)
            .hasMatch(m.group(1)!), isFalse,
            reason: '${f.uri.pathSegments.last}: a \$\$-quoted body nested '
                'inside a do \$\$ block cannot parse — tag the outer block');
      }
    }
  });

  test('every table the client queries is created by a migration', () {
    // care_nudges existed only in the production dashboard, so a fresh
    // database had nothing for care_call_push's trigger to attach to and the
    // replay stopped dead. That one failed loudly because a MIGRATION
    // referenced it; a table only the CLIENT touches fails silently instead —
    // the replay succeeds and the app breaks for the first real user.
    final sql = sqlIn(migrations).map((f) => f.readAsStringSync()).join('\n');
    final created = RegExp(
            r'create table(?:\s+if not exists)?\s+public\.(\w+)',
            caseSensitive: false)
        .allMatches(sql)
        .map((m) => m[1]!.toLowerCase())
        .toSet();

    final used = <String, String>{};
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in RegExp(r"\.from\(\s*'([a-z_]+)'").allMatches(src)) {
        // .storage.from('bucket') is a storage bucket, not a table — and the
        // call is routinely split across lines, so a one-word lookback misses
        // it. Scan a window back from the match instead.
        final from = m.start - 60 < 0 ? 0 : m.start - 60;
        if (src.substring(from, m.start).contains('storage')) continue;
        used[m[1]!] = f.uri.pathSegments.last;
      }
      for (final m in RegExp(r"table:\s*'([a-z_]+)'").allMatches(src)) {
        used[m[1]!] = f.uri.pathSegments.last;
      }
    }

    // Known gap, tracked: these three predate the migration directory and
    // their real shape is only in the production dashboard. Reconstructing
    // them requires dumping production, not reading the client.
    // Was a tracked gap; all three are now reconstructed from production.
    const knownMissing = <String>{};

    final missing = used.keys
        .where((t) => !created.contains(t) && !knownMissing.contains(t))
        .toList()
      ..sort();
    expect(missing, isEmpty,
        reason: 'queried by the client, created by no migration: '
            '${missing.map((t) => '$t (${used[t]})').join(', ')}');
  });

  test('every dollar-quote tag appears an even number of times', () {
    // Catches the mistake the second replay found, which the nesting check
    // above does not: a tag named inside a COMMENT within its own block.
    // Dollar quoting ignores SQL comments, so writing the tag in an
    // explanatory comment closes the block early — the error then points at
    // whatever word follows, several lines from the real cause.
    for (final f in sqlIn(migrations)) {
      final src = f.readAsStringSync();
      final tags = RegExp(r'\$[a-z_]*\$').allMatches(src).map((m) => m[0]!);
      for (final tag in tags.toSet()) {
        final n = tag.allMatches(src).length;
        expect(n.isEven, isTrue,
            reason: '${f.uri.pathSegments.last}: tag $tag appears $n times — '
                'an odd count means one is inside a comment or a string');
      }
    }
  });

  test('cron.unschedule is guarded before it is called', () {
    // cron.unschedule RAISES when the job does not exist, so on a database
    // that has never run the file the statement aborts before scheduling
    // anything. Every call must be gated on cron.job.
    for (final f in sqlIn(migrations)) {
      final src = f.readAsStringSync();
      if (!src.contains('cron.unschedule')) continue;
      expect(src, contains('from cron.job'),
          reason: '${f.uri.pathSegments.last}: unguarded cron.unschedule '
              'fails on any database where the job is absent');
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
