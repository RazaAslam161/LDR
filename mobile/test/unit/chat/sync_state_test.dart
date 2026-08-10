import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Four defects with one shape: durable facts were being derived from
/// ephemeral ones.
///
/// A read receipt is durable — once she has read a message, she has read it.
/// "Is she in the chat right now" is ephemeral. Storing both in one column
/// forced the code to move the read watermark BACKWARDS to express "she left",
/// which un-read every message she had already read. That is the whole bug, and
/// it is a modelling error rather than a UI one.
void main() {
  String read(String p) => File(p).readAsStringSync();

  /// Code only. These tests assert what the code DOES, and the comments here
  /// deliberately name the removed behaviour to explain why it is gone —
  /// grepping them made a correct fix look like a regression.
  String codeOnly(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  final presence = read('lib/core/services/presence_service.dart');
  final chat = read('lib/features/chat/chat_screen.dart');
  final tz = read('lib/core/time/tz_helper.dart');
  final welcome = read('lib/features/auth/welcome_page.dart');
  final location = read('lib/core/services/location_service.dart');
  final main_ = read('lib/main.dart');

  group('a read receipt cannot un-read itself', () {
    test('leaving the chat does not rewrite the read watermark', () {
      // It used to write chat_last_read five minutes into the past, purely to
      // make isActivelyInChat false. Every green tick in the conversation went
      // black the moment she closed the chat.
      final fn = presence.substring(presence.indexOf('clearChatPresence'));
      final body = codeOnly(fn.substring(0, fn.indexOf('});')));
      expect(body.contains('chat_last_read'), isFalse,
          reason: 'a watermark that moves backwards un-reads read messages',);
      expect(body, contains('typing_in_chat'),
          reason: '"she left the chat" belongs in its own field',);
    });

    test('"in chat now" is derived from its own field, not the watermark', () {
      final g = presence.substring(presence.indexOf('bool get isActivelyInChat'));
      final body = codeOnly(g.substring(0, g.indexOf(';') + 1));
      expect(body, contains('typingInChat'));
      expect(body.contains('chatLastRead'), isFalse,
          reason: 'coupling these is what forced the watermark to move back',);
    });

    test('seen involves no clock at all', () {
      // This test used to REQUIRE chatLastRead here, pinning the defect as if
      // it were the fix. chat_last_read is stamped by the READER'S PHONE and
      // was compared against created_at, stamped by POSTGRES — two clocks, one
      // inequality, one second of slop. A reader 40s slow left messages on a
      // black tick long after reading them; a reader running fast marked
      // messages seen that were never on screen. Receipts are server-assigned
      // integers now, so no device clock participates.
      final fn = chat.substring(chat.indexOf('_MsgStatus _statusFor'));
      final body = codeOnly(fn.substring(0, fn.indexOf('\n  }')));
      expect(body.contains('isActivelyInChat'), isFalse,
          reason: 'whether a message was read cannot depend on who is online',);
      expect(body.contains('chatLastRead'), isFalse,
          reason: "comparing two devices' clocks is the bug, not the fix",);
      expect(body, contains('readSeq'));
      expect(body, contains('deliveredSeq'));
    });
  });

  group('the device already knows the timezone', () {
    test('detection matches by offset, not by name', () {
      // DateTime.now().timeZoneName is an abbreviation ('PKT'); the list holds
      // IANA names ('Asia/Karachi'). Comparing them never matched, so every
      // user on earth silently got the first entry, America/Los_Angeles.
      expect(tz, contains('static String deviceZone'));
      expect(welcome, contains('TzHelper.deviceZone'));
      expect(welcome.contains('DateTime.now().timeZoneName'), isFalse,
          reason: 'an abbreviation can never match an IANA name',);
    });

    test('it is re-checked on resume, not only at onboarding', () {
      expect(main_, contains('syncTimezone'));
    });
  });

  test('granting location permission turns sharing on', () {
    // The app asked for the permission and then left sharing 'off', so granting
    // it did nothing until the user found the second switch in Settings.
    expect(location, contains('adoptPermissionAsDefault'));
    final fn = location.substring(location.indexOf('adoptPermissionAsDefault'));
    final body = fn.substring(0, fn.indexOf('\n  }'));
    expect(body, contains("'city'"),
        reason: 'coarse is the polite default for something enabled for you',);
    expect(body, contains('location_mode_defaulted'),
        reason: "once only — after that the stored mode is the user's choice",);
    expect(body, contains("!= 'off'"),
        reason: 'must never override a mode the user picked themselves',);
  });

  group('returning to the app refreshes it', () {
    test('resume triggers a refresh', () {
      // Realtime only carries what happens after it reconnects, so anything
      // that changed while the socket was down was missed — and the app looked
      // stale until it was killed and relaunched.
      expect(main_, contains('_refreshOnResume'));
    });

    test('the refresh is throttled', () {
      // It fires on every return from every picker and camera, for every user.
      // An unthrottled fan-out of queries here is a scaling defect.
      final fn = main_.substring(main_.indexOf('Future<void> _refreshOnResume'));
      final body = fn.substring(0, fn.indexOf('\n  }'));
      expect(body, contains('_lastResumeRefresh'));
      expect(body, contains('Duration(seconds: 10)'));
    });
  });
}
