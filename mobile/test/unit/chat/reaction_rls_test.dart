import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The database half of reactions, pinned against the migration that carries
/// it.
///
/// The BEHAVIOUR was proven where behaviour can be proven — against staging and
/// then production, as a third account that is in neither person's couple. Every
/// forge attempt came back 42501 and every read came back zero rows; the run is
/// recorded in BRAIN.md §70. A Dart test cannot re-run that, and pretending
/// otherwise would be worse than saying so.
///
/// What it CAN hold is the shape of the policy that produced those numbers, so
/// a later edit cannot quietly widen it. One clause in particular: the insert
/// policy has to say which table's `message_id` it means. Unqualified, the name
/// binds to the subquery's own table and the check becomes `m.id = m.id` — a
/// tautology that passes everything, raises nothing, and would let anyone
/// attach a reaction to any message in the database.
void main() {
  final file = File(
      '../supabase/migrations/20260819090000_message_reactions.sql',);
  late String sql;

  /// The same file with its `--` commentary removed. The migration explains
  /// itself at length, and prose about what the change does NOT do would
  /// otherwise read as the change doing it.
  late String ddl;

  setUpAll(() {
    expect(file.existsSync(), isTrue,
        reason: 'the reactions migration is the feature — without it in the '
            'repo the database is not reproducible from this tree',);
    sql = file.readAsStringSync().toLowerCase();
    ddl = sql
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('--'))
        .join('\n');
  });

  test('one reaction per person per message', () {
    // The primary key IS the rule. Without it "remove mine" is ambiguous and a
    // count can exceed the two people in the couple.
    expect(sql, contains('primary key (message_id, user_id)'));
  });

  test('the emoji is stored sealed, with no plaintext column beside it', () {
    expect(sql, contains('emoji_cipher bytea'));
    expect(sql, contains('emoji_nonce  bytea'));
    // A plaintext column is what bodies need for clients already in the field.
    // Nothing has ever read this table, so there is no such client and no
    // reason to keep a readable copy.
    expect(RegExp(r'\bemoji\s+text\b').hasMatch(sql), isFalse);
  });

  test('row level security is on, with all four verbs scoped', () {
    expect(sql, contains('enable row level security'));
    for (final verb in ['for select', 'for insert', 'for update', 'for delete']) {
      expect(sql, contains(verb), reason: 'no $verb policy');
    }
    // Reading is couple-scoped; writing is your own row in your own couple.
    expect(sql, contains('couple_id = (select public.current_user_couple_id())'));
    expect(sql, contains('user_id = (select auth.uid())'));
  });

  test('the insert check names the table whose message_id it means', () {
    // The tautology trap. `where m.id = message_id` binds to the SUBQUERY's
    // table and always passes.
    expect(sql, contains('m.id = public.message_reactions.message_id'));
    expect(sql, contains('from public.messages m'));
    // And not one that is already gone: an offline client whose outbox retries
    // minutes after a "delete for everyone" would otherwise put the ciphertext
    // straight back on a message whose body has been scrubbed.
    expect(sql, contains('and not m.deleted_for_everyone'));
  });

  test('a second run is a no-op, not an error', () {
    expect(sql, contains('create table if not exists'));
    expect(RegExp('create index if not exists').allMatches(sql).length,
        greaterThanOrEqualTo(2),);
    // `create policy` errors on a repeat, so each one is dropped first.
    final creates = RegExp('create policy').allMatches(sql).length;
    final drops = RegExp('drop policy if exists').allMatches(sql).length;
    expect(drops, creates);
    // `alter publication ... add table` is the other statement that errors on
    // a repeat, so it is guarded on the catalogue.
    expect(sql, contains('from pg_publication_tables'));
  });

  test('the table states its own grants', () {
    // A new table takes whatever pg_default_acl mints, and the two projects do
    // not agree: created without these lines it came out on STAGING with anon
    // and authenticated both holding TRUNCATE — which consults no policy at
    // all, and the anon key ships inside the APK.
    expect(ddl, contains('revoke all on public.message_reactions from anon'));
    expect(ddl, contains('revoke truncate, references, trigger'));
    expect(ddl,
        contains('grant select, insert, update, delete on '
            'public.message_reactions to authenticated'),);
  });

  test('a message deleted for everyone takes its reactions with it', () {
    // The RPC flags the message rather than deleting it, so `on delete
    // cascade` never fires: without this the ciphertext of what somebody felt
    // about a deleted message outlives the message itself.
    final scrub = File('../supabase/migrations/'
            '20260819100000_delete_for_everyone_takes_the_reactions.sql')
        .readAsStringSync()
        .toLowerCase();
    expect(scrub,
        contains('delete from public.message_reactions where message_id'),);
    // SECURITY DEFINER: unguarded, anyone who can call it could erase the
    // reactions on any message id they can guess.
    expect(scrub, contains('if found then'));
    expect(scrub.indexOf('if found then'),
        lessThan(scrub.indexOf('delete from public.message_reactions where')),);
  });

  test('removals reach the partner: replica identity is full', () {
    // Under the default (primary key) replica identity a DELETE carries only
    // the key columns, so a client filtered on couple_id sees no removal at
    // all — the reaction stays on their screen until they reopen the chat.
    expect(sql, contains('replica identity full'));
  });

  test('the rollback is written down, in the order it has to happen', () {
    expect(sql, contains('drop table if exists public.message_reactions'));
    // A PL/pgSQL body is not a tracked dependency, so dropping the table while
    // delete_message_for_everyone still references it succeeds silently and
    // leaves every "delete for everyone" raising 42P01 — taking the body
    // scrub down with it in the same transaction.
    expect(sql, contains('order matters'));
    expect(sql, contains('20260818160000'));
  });

  test('nothing here is subtractive', () {
    // Shipped APKs keep reading the old shape forever. The only drops in this
    // file are of policies on the table it is creating.
    expect(ddl.contains('drop column'), isFalse);
    expect(ddl.contains('rename'), isFalse);
    expect(ddl.contains('drop table'), isFalse,
        reason: 'the rollback belongs in the header, never in the forward '
            'migration',);
    expect(ddl.contains('alter table public.messages'), isFalse,
        reason: 'reactions must not touch the messages table — delivery '
            'receipts and the push trigger both live on it',);
  });

  test('a reaction cannot become a notification', () {
    // The only push in the schema is `message_notify_on_insert` on
    // public.messages. This table gets no trigger of its own, so there is no
    // path from a reaction to a notification a disguised build could not post.
    expect(RegExp('create trigger').hasMatch(ddl), isFalse);
    expect(ddl.contains('net.http_post'), isFalse);
  });
}
