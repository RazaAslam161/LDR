import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A new bucket that no delete path knows about is "a breakup left the
/// photographs on disk forever" again, with a new prefix.
///
/// couple_files is swept by four functions, each of which enumerates buckets
/// as string literals. Adding one means editing all four, and nothing in
/// Postgres complains if you edit three — the fourth just quietly keeps
/// somebody's documents.
void main() {
  List<File> migrations() =>
      (Directory('../supabase/migrations').listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
          .where((f) => f.path.endsWith('.sql'))
          .toList();

  /// The LAST migration that redefines [fn] — the one that actually wins on a
  /// replay. Reading the first would assert against a definition three
  /// migrations have since replaced.
  String latestDefinitionOf(String fn) {
    final defining = migrations()
        .where((f) =>
            f.readAsStringSync().contains('function public.$fn('),)
        .toList();
    expect(defining, isNotEmpty, reason: 'nothing defines $fn');
    final src = defining.last.readAsStringSync();
    final start = src.indexOf('create or replace function public.$fn(');
    expect(start, greaterThan(-1), reason: '$fn is named but not defined');
    return src.substring(start);
  }

  test('every sweep that removes a couple\'s media removes its files', () {
    for (final fn in [
      'delete_message_for_everyone',
      'clear_conversation_everyone',
      'delete_my_account',
      'prune_dissolved_couples',
    ]) {
      expect(latestDefinitionOf(fn), contains("'couple_files'"),
          reason: '$fn leaves documents in storage forever',);
    }
  });

  test('the per-message sweeps delete by the column that names the object', () {
    // The folder-prefix sweep only fires when the last member of a couple
    // goes. Deleting one message, or clearing one conversation, has to find
    // the object through messages.file_path.
    for (final fn in [
      'delete_message_for_everyone',
      'clear_conversation_everyone',
    ]) {
      expect(latestDefinitionOf(fn), contains('file_path'), reason: fn);
    }
  });

  test('the bucket is private and bounded', () {
    // The audit found every bucket accepting any file at any size. This one
    // deliberately takes any TYPE — it is a documents bucket — so the size
    // limit is the whole of what bounds it.
    final sql = migrations()
        .firstWhere((f) => f.path.endsWith('_document_messages.sql'))
        .readAsStringSync();
    expect(sql, contains("values ('couple_files', 'couple_files', false"));
    expect(sql, contains('file_size_limit = 26214400'));
    // Read, write and delete, each scoped to the caller's own couple folder.
    expect(RegExp('current_user_couple_id').allMatches(sql).length,
        greaterThanOrEqualTo(3),);
  });
}
