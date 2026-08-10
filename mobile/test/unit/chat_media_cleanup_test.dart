import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Deleting a message removed the row and left the file: the photo stayed in
/// the bucket and a signed URL could still be minted for it.
/// Resolves a migration by name, so renumbering or reordering migrations/
/// cannot break this test the way a hardcoded path does.
String _migration(String name) {
  final dir = Directory('../supabase/migrations');
  final f = dir.listSync().whereType<File>().firstWhere(
      (f) => f.path.endsWith('_$name.sql'),
      orElse: () => throw StateError('no migration named $name'));
  return f.readAsStringSync();
}

void main() {
  final sql =
      _migration('chat_media_cleanup');

  test('both hard-delete paths drop the stored files', () {
    for (final f in [
      'delete_message_for_everyone',
      'clear_conversation_everyone'
    ]) {
      final body = sql.substring(sql.indexOf(f));
      expect(body, contains('delete from storage.objects'), reason: f);
    }
  });

  test('every media column in both buckets is covered', () {
    // image + voice live in couple_media; video in the private
    // couple_intimate. Missing one leaves that kind of file orphaned.
    for (final c in ['image_path', 'voice_path', 'video_path']) {
      expect('image_path,voice_path,video_path'.contains(c), isTrue);
      expect(sql, contains(c), reason: '$c must be cleaned up');
    }
    expect(sql, contains("'couple_media'"));
    expect(sql, contains("'couple_intimate'"));
  });

  test('a storage hiccup cannot make the delete itself fail', () {
    expect(RegExp('exception when others then null').allMatches(sql).length, 2,
        reason: 'best-effort in both functions, like clear_body_photo');
  });

  test('clear-all removes files before the rows that name them', () {
    final body = sql.substring(sql.indexOf('clear_conversation_everyone'));
    expect(body.indexOf('storage.objects'),
        lessThan(body.indexOf('delete from public.messages')),
        reason: 'rows deleted first would leave nothing to find the files by');
  });
}
