import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// leave_couple() has lost its presence privacy wipe once already, and silently.
///
/// 20260601002400 added a 16-column scrub with a long ordering note.
/// 20260601005100 replaced the function to add dissolved_at and dropped the
/// scrub entirely; 20260815071024 inherited the shortened body. Nothing failed.
/// The one test that mentions the wipe — migrations_hygiene_test's
/// 'presence_server_time precedes newuser_fixes' — only names it in a comment
/// while asserting something else, so it stayed green throughout.
///
/// The assertion block inside 20260826140000 catches a new presence COLUMN
/// going undecided. It cannot catch what actually happened: someone
/// `create or replace`-ing the whole function for an unrelated reason and
/// carrying the scrub away with it. That is this file's job.
void main() {
  final dir = Directory('../supabase/migrations');

  /// The last definition in replay order is the one production runs. Lexical
  /// order IS replay order here — the 14-digit prefix is the ordering key.
  String liveDefinitionOf(String function) {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    String? live;
    for (final f in files) {
      final src = f.readAsStringSync();
      final i = src.toLowerCase().indexOf('function public.$function()');
      if (i < 0) continue;
      live = src.substring(i);
    }
    expect(live, isNotNull, reason: '$function is defined nowhere');
    return live!;
  }

  test('the live leave_couple still scrubs presence', () {
    final def = liveDefinitionOf('leave_couple');
    // Every field a next partner would otherwise inherit from the last one.
    const mustClear = [
      'latitude',
      'longitude',
      'location_accuracy',
      'location_label',
      'location_sharing_mode',
      'location_updated_at',
      'current_mood',
      'mood_color',
      'mood_updated_at',
      'current_activity',
      'current_screen',
      'body_photo_path',
      'avatar_emoji',
      'checkin_photo_url',
      'checkin_photo_at',
      'chat_last_read',
      'app_last_active_at',
    ];
    for (final column in mustClear) {
      expect(def.contains(column), isTrue,
          reason: 'leave_couple() no longer clears presence.$column — a new '
              'partner inherits it when sync_presence_couple_id re-attaches '
              'the row',);
    }
  });

  test('the scrub runs before the profiles update', () {
    // The ordering note from 20260601002400 is still load-bearing:
    // trg_sync_presence_couple_id nulls presence.couple_id the instant
    // profiles.couple_id changes, so a scrub placed after it matches zero rows
    // and silently does nothing — indistinguishable from a scrub that worked.
    final def = liveDefinitionOf('leave_couple');
    final scrub = def.indexOf('update public.presence');
    final profiles = def.indexOf('update public.profiles');
    expect(scrub, greaterThan(-1), reason: 'the presence scrub has gone');
    expect(profiles, greaterThan(-1));
    expect(scrub, lessThan(profiles),
        reason: 'the presence scrub must precede the profiles update',);
  });

  test('the photographs are queued for the reaper, never deleted directly', () {
    // A `delete from storage.objects` destroys the version column that is the
    // only pointer to the bytes, leaving them billed and un-erasable forever.
    final def = liveDefinitionOf('leave_couple');
    expect(def.contains('storage_reap'), isTrue,
        reason: 'body_photo_path / checkin_photo_url objects must be queued',);
    expect(def.contains('delete from storage.objects'), isFalse);
  });

  test('location sharing is switched off rather than nulled', () {
    // location_sharing_mode is NOT NULL, and 'off' is the only value that does
    // not re-arm live sharing the moment the row is re-attached. Two rows in
    // production were measured sitting at a sharing mode nobody turned on.
    final def = liveDefinitionOf('leave_couple');
    expect(def.contains("location_sharing_mode = 'off'"), isTrue);
  });
}
