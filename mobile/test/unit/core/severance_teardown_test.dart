import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Unpair never ran the local wipe, because the wipe was wired to an event a
/// breakup does not raise: leaveCouple() ends with refreshSession(), which
/// fires `tokenRefreshed`, not `signedOut`. So the decrypted photographs, the
/// voice notes, the unsent draft, the ex-partner's name and an armed send
/// queue all survived it.
///
/// These pin the split. The failure mode they exist for is drift: someone adds
/// a store to _endSession and not to endCouple, and unpair silently starts
/// leaking again with every gate still green.
///
/// Source-level rather than behavioural, for the reason onboarding_escape_test
/// gives — reaching this path needs a live Supabase session, so a widget test
/// would assert against mocks rather than against the thing that broke.
void main() {
  String read(String path) => File(path).readAsStringSync();

  /// Whole-line comments stripped. Without this these checks match the
  /// comments that EXPLAIN the rule — "there must never be a SnackBarAction
  /// here" contains the very string it forbids — and the test passes or fails
  /// on prose rather than on code.
  String code(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  late String session;
  late String endCouple;

  setUpAll(() {
    session = read('lib/core/app/session_provider.dart');
    final start = session.indexOf('Future<void> endCouple(String? coupleId)');
    final end = session.indexOf('Future<void> _endSession()');
    expect(start, greaterThan(-1), reason: 'endCouple() has gone');
    expect(end, greaterThan(start), reason: '_endSession must follow endCouple');
    endCouple = code(session.substring(start, end));
  });

  test('_endSession delegates the couple-scoped half to endCouple', () {
    expect(session.contains('await endCouple('), isTrue);
  });

  test('endCouple drops everything that belonged to the couple', () {
    // Each of these is the ex-partner's bytes, or an action still armed and
    // aimed at them. Every one survived an unpair before this landed.
    const mustClear = [
      'removeChannel(',
      'MediaUrls.clear()',
      'MapToken.clear()',
      'ChatSendQueue.instance.clear()',
      'ChatReactionOutbox.instance.endSession()',
      'GalleryScreen.clearFailedUploads()',
      'ChatDraftStore.clearAll()',
      'EncryptedMediaCache.clearAll()',
      'DefaultCacheManager().emptyCache()',
      // The store chat and the gallery actually paint from since they moved
      // off the 200-object singleton. Emptying only the singleton would leave
      // every photograph on disk under a stable key.
      'PlainMediaCache.clearAll()',
      // The grid's remembered list: the couple's storage paths, with live
      // 24-hour URLs still in MediaUrls for every one of them.
      'GalleryRepository.forgetSnapshots()',
      'VoiceNoteCache.clearAll()',
      'imageCache',
      'pendingMemory.value = null',
      'LoveNoteRecipient.clear()',
      'UnreadTally.clear(',
      'CryptoCore.forgetPartner()',
      'CoupleKey.reset()',
    ];
    for (final call in mustClear) {
      expect(endCouple.contains(call), isTrue,
          reason: '$call must run when a couple ends');
    }
  });

  test('endCouple keeps what belongs to the account, not the couple', () {
    // The account is still signed in. forgetAccount() would drop its own seed
    // handle and reset `keyless`, which the /rewrap gate reads — hiding a real
    // rewrap-needed state behind a breakup. forgetDevice() would unbind push
    // for an account that still needs its own notifications. TermsGate and
    // ContactPause are per-account and per-user; a mute that silently lifted
    // itself at the moment of a breakup is exactly backwards.
    const mustNotRun = [
      'CryptoCore.forgetAccount()',
      'FcmService.forgetDevice()',
      'TermsGate.reset()',
      'ContactPause.reset()',
    ];
    for (final call in mustNotRun) {
      expect(endCouple.contains(call), isFalse,
          reason: '$call is account-scoped and must not run on unpair');
    }
  });

  test('the partner key pin survives an unpair', () {
    // It looks like leftover state and it is not. The pin is the only record
    // that would make a GENUINE key substitution visible if these two accounts
    // pair again; clearing it silently downgrades the pair back to
    // trust-on-first-use. The next person to read endCouple will want to clear
    // it, which is why this is pinned rather than commented.
    expect(endCouple.contains('PartnerKeyPin'), isFalse);
  });
}
