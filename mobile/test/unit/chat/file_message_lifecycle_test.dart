import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A new bucket that no delete path knows about is "a breakup left the
/// photographs on disk forever" again, with a new prefix.
///
/// couple_files is swept by several functions that enumerate buckets as string
/// literals. Adding a bucket means editing every one of them, and nothing in
/// Postgres complains if you edit all but one — that one just quietly keeps
/// somebody's documents.
///
/// Since 20260826170000 the sweep can also be reached by DELEGATION:
/// prune_dissolved_couples no longer enumerates buckets itself, it calls
/// purge_couple, which does. That is the direction this test wants — one copy
/// of the list rather than four — so the check follows a delegation instead of
/// insisting the literal appears in the caller.
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
    // Bounded at the next definition. Reading to end-of-file let a function
    // pass on a bucket literal that belonged to a DIFFERENT function further
    // down the same migration.
    final rest = src.indexOf('create or replace function public.', start + 1);
    return rest == -1 ? src.substring(start) : src.substring(start, rest);
  }

  /// True when [fn] sweeps couple_files itself, or hands the job to something
  /// that does. One level of indirection is enough: the point is that no path
  /// which removes a couple's media forgets its documents.
  bool sweepsCoupleFiles(String fn) {
    final def = latestDefinitionOf(fn);
    if (def.contains("'couple_files'")) return true;
    for (final delegate in ['purge_couple']) {
      if (def.contains('public.$delegate(') &&
          latestDefinitionOf(delegate).contains("'couple_files'")) {
        return true;
      }
    }
    return false;
  }

  test('every sweep that removes a couple\'s media removes its files', () {
    for (final fn in [
      'delete_message_for_everyone',
      'clear_conversation_everyone',
      'delete_my_account',
      'prune_dissolved_couples',
      // The immediate half of the same sweep. leave_couple_permanently reaches
      // storage only through this, so if it ever stops naming couple_files the
      // permanent exit starts leaving documents behind.
      'purge_couple',
    ]) {
      expect(sweepsCoupleFiles(fn), isTrue,
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
