import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/widgets/safety_code_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The arithmetic behind [SafetyCodePrompt.shouldAsk].
///
/// The prompt closes the one hole the pin cannot: a directory that substitutes
/// a key on the FIRST fetch is pinned as faithfully as a real one, and only the
/// two people can catch it, by comparing the twenty digits. Everything that
/// makes that ask worth anything is in these four properties — it fires while
/// the answer is unknown, it stops for good once a human has answered for that
/// key, a rotation is a NEW question rather than an inherited answer, and a
/// second account on the same handset starts with no answers at all.
///
/// The preference keys are spelled out as literals here on purpose, the same
/// bargain escrow_prompt_snooze_test.dart strikes: they are what is actually
/// sitting in users' prefs files, so a rename in lib is a migration and has to
/// fail here rather than be absorbed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Real 32-byte keys rather than stand-in strings: the record is scoped by the
  // code, and the code is a hash of the two keys, so "a different partner key"
  // has to actually be a different key for the rotation test to mean anything.
  final myPub = base64Encode(List<int>.filled(32, 3));
  final partnerPub = base64Encode(List<int>.filled(32, 7));
  final rotatedPub = base64Encode(List<int>.filled(32, 9));

  final code = PartnerKeyPin.safetyCode(myPub, partnerPub);
  final rotatedCode = PartnerKeyPin.safetyCode(myPub, rotatedPub);

  String verifiedKey(String uid, String c) =>
      'safety_code_verified_v1:$uid:${sha256.convert(utf8.encode(c))}';
  String declinedAtKey(String uid) => 'safety_code_declined_at_v1:$uid';

  final now = DateTime(2026, 8, 18);
  int msAgo(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  Future<SharedPreferences> prefsWith(Map<String, Object> values) {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  Future<String?> Function() codeIs(String? c) => () async => c;

  test('a key nobody has compared is asked about', () async {
    final prefs = await prefsWith({});
    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-1',
        code: codeIs(code),
        now: now,
      ),
      isTrue,
    );
  });

  test('a comparison retires the question for that key, permanently', () async {
    final prefs = await prefsWith({});
    await SafetyCodePrompt.record(prefs, uid: 'acc-1', code: code, now: now);

    expect(
      prefs.getInt(verifiedKey('acc-1', code)),
      now.millisecondsSinceEpoch,
      reason: 'the record must land under the key shipped builds read',
    );
    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-1',
        code: codeIs(code),
        now: now,
      ),
      isFalse,
    );
    // A year on it is still answered. Only a decline expires — a comparison
    // that happened stays happened, and re-asking about a key nothing has
    // changed is the nagging that gets security prompts tapped past.
    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-1',
        code: codeIs(code),
        now: now.add(const Duration(days: 365)),
      ),
      isFalse,
    );
  });

  test('a rotated partner key re-arms the question exactly once', () async {
    expect(rotatedCode, isNot(code), reason: 'the fixture keys must differ');
    final prefs = await prefsWith(
      {verifiedKey('acc-1', code): msAgo(const Duration(days: 30))},
    );

    // The reinstall / new phone / rewrap case. The old answer was about the
    // old key and says nothing about this one.
    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-1',
        code: codeIs(rotatedCode),
        now: now,
      ),
      isTrue,
    );

    await SafetyCodePrompt.record(
      prefs,
      uid: 'acc-1',
      code: rotatedCode,
      now: now,
    );
    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-1',
        code: codeIs(rotatedCode),
        now: now,
      ),
      isFalse,
      reason: 'once, not once per launch',
    );
    expect(
      prefs.getInt(verifiedKey('acc-1', code)),
      msAgo(const Duration(days: 30)),
      reason: 'answering for the new key must not rewrite the old record',
    );
  });

  test('a decline buys a week of silence, and costs no fetch', () async {
    var calls = 0;
    Future<String?> counted() async {
      calls++;
      return code;
    }

    final prefs =
        await prefsWith({declinedAtKey('acc-1'): msAgo(const Duration(days: 6))});
    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-1',
        code: counted,
        now: now,
      ),
      isFalse,
    );
    expect(
      calls,
      0,
      reason: 'a snoozed launch must not fetch the partner key',
    );

    // And it is a snooze, not an exemption: the question comes back while it
    // is still unanswered.
    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-1',
        code: counted,
        now: now.add(const Duration(days: 1)),
      ),
      isTrue,
    );
    expect(calls, 1);
  });

  test('a second account on the same handset inherits nothing', () async {
    // Deliberately the SAME code under both accounts: it is the only shape in
    // which a scoping bug is visible, since anything that keyed on the code
    // alone would answer acc-2 out of acc-1's record.
    final prefs = await prefsWith({
      verifiedKey('acc-1', code): msAgo(const Duration(days: 1)),
      declinedAtKey('acc-1'): msAgo(const Duration(days: 1)),
    });

    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-2',
        code: codeIs(code),
        now: now,
      ),
      isTrue,
    );

    await SafetyCodePrompt.record(prefs, uid: 'acc-2', code: code, now: now);
    expect(
      prefs.getInt(verifiedKey('acc-1', code)),
      msAgo(const Duration(days: 1)),
      reason: "one account's answer must not move another's",
    );
  });

  test('nothing to compare is not an answer', () async {
    // No partner key published yet, or the fetch did not land. Neither asks
    // nor records: an unreachable directory is not a verification, and it must
    // not spend the one ask this key gets either.
    final prefs = await prefsWith({});
    expect(
      await SafetyCodePrompt.shouldAsk(
        prefs,
        uid: 'acc-1',
        code: codeIs(null),
        now: now,
      ),
      isFalse,
    );
    expect(prefs.getKeys(), isEmpty);
  });
}
