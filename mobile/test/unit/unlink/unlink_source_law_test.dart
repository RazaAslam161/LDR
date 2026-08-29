import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The ceremony's structural laws, source-read where behaviour needs a
/// database or a platform to exercise.
void main() {
  final banner =
      File('lib/features/unlink/unlink_banner.dart').readAsStringSync();
  final shell =
      File('lib/features/shell/app_shell.dart').readAsStringSync();
  final repo =
      File('lib/features/unlink/unlink_repository.dart').readAsStringSync();
  final main_ = File('lib/main.dart').readAsStringSync();
  final unlinkDir = Directory('lib/features/unlink')
      .listSync()
      .whereType<File>()
      .map((f) => f.readAsStringSync())
      .join('\n');

  test('the banner is a root-Stack overlay, by the root-Stack rules', () {
    expect(banner.contains('Positioned('), isTrue,
        reason: 'a non-Positioned child would break every overlay above it',);
    expect(banner.contains('TextDecoration.none'), isTrue,
        reason: 'no Material ancestor exists in the root Stack',);
    expect(banner.contains('Scaffold'), isFalse);
    expect(main_.contains('const UnlinkBanner(),'), isTrue,
        reason: 'the seven-day clock must not depend on which page is open',);
  });

  test('the shell listens through the managed channel, never hand-rolled',
      () {
    final at = shell.indexOf("channelName: 'unlink:");
    expect(at, greaterThan(-1));
    expect(
        shell
            .substring(at - 300, at)
            .contains('ManagedSubscription.start'),
        isTrue,
        reason: 'a raw channel dies silently on the first reconnect',);
    expect(shell.contains("table: 'couple_unlink'"), isTrue);
  });

  test('realtime events are signals — the row is always refetched', () {
    // The handler must reload over PostgREST, never parse the payload:
    // realtime serializes bytea differently and the note would corrupt.
    final at = shell.indexOf('Future<void> _onUnlinkChanged()');
    expect(at, greaterThan(-1));
    final body = shell.substring(at, at + 1200);
    expect(body.contains('UnlinkState.load()'), isTrue);
    expect(body.contains('payload'), isFalse);
  });

  test('exactly one AAD builder', () {
    expect('unlink_note:'.allMatches(repo).length, 1,
        reason: 'two spellings of the AAD is how seal and open drift apart',);
  });

  test('the feature sends nothing itself — the DB trigger owns the telling',
      () {
    expect(unlinkDir.contains('FcmService'), isFalse);
    expect(unlinkDir.contains('http_post'), isFalse);
  });

  test('execution happens on human presence, from either phone', () {
    final at = shell.indexOf('Future<void> _executeUnlink(');
    expect(at, greaterThan(-1));
    final body = shell.substring(at, at + 1200);
    expect(body.contains('UnlinkRepository.execute()'), isTrue);
    expect(body.contains('endCouple('), isTrue);
    expect(body.contains('loadProfile()'), isTrue,
        reason: "the pinned teardown order, with the RPC in leaveCouple's "
            'seat',);
  });
}
