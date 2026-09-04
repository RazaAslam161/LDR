import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/legal/terms_gate.dart';
import 'package:miles/features/legal/terms_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The gate stands in front of every screen that can put content into this
/// app, so the only interesting question about it is what it does when it does
/// not know the answer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TermsGate.reset();
    TermsGate.currentAccount = () => 'user-a';
    TermsGate.fetchAcceptedVersion = () async => null;
    TermsGate.recordAcceptance = (_) async {};
  });

  group('needsAcceptance', () {
    test('the version constant is 2; these cases are written against it', () {
      // If someone raises the version, the numbers below stop meaning what
      // they say and this fails first rather than the assertions fifty lines
      // down failing mysteriously.
      //
      // It did exactly that on 2026-09-04, which is why the cases below moved:
      // v1 told every user that files in the private vault were end-to-end
      // encrypted, and they never were on any build this gate has seen. A
      // corrected security guarantee is the "change that matters" the Terms
      // themselves promise to re-ask for, so the constant went 1 -> 2 and
      // accepting v1 no longer opens the gate.
      expect(milesTermsVersion, 2);
    });

    test('null — never asked, or the answer was lost — gates', () async {
      TermsGate.fetchAcceptedVersion = () async => null;
      await TermsGate.load();
      expect(TermsGate.acceptedVersion, isNull);
      expect(TermsGate.needsAcceptance, isTrue);
    });

    test('0 — a version older than any published — gates', () async {
      TermsGate.fetchAcceptedVersion = () async => 0;
      await TermsGate.load();
      expect(TermsGate.needsAcceptance, isTrue);
    });

    test('1 — the superseded version — gates', () async {
      // The whole point of the bump. Everyone on record as accepting v1
      // accepted a document that misdescribed the vault, so they are asked
      // again rather than left holding it.
      TermsGate.fetchAcceptedVersion = () async => 1;
      await TermsGate.load();
      expect(TermsGate.needsAcceptance, isTrue);
      expect(TermsGate.accepted.value, isFalse);
    });

    test('2 — the current version — opens', () async {
      TermsGate.fetchAcceptedVersion = () async => 2;
      await TermsGate.load();
      expect(TermsGate.needsAcceptance, isFalse);
      expect(TermsGate.accepted.value, isTrue);
    });

    test('3 — a newer version than this build knows — opens', () async {
      // A handset that accepted v3 elsewhere must not be re-gated by an older
      // build. Downgrades are a real event here.
      TermsGate.fetchAcceptedVersion = () async => 3;
      await TermsGate.load();
      expect(TermsGate.needsAcceptance, isFalse);
    });
  });

  group('fails closed', () {
    test('a load that throws leaves the gate SHUT', () async {
      // The one that matters. A gate that opens because its own check broke is
      // not a gate — and every upload path in the app is behind this one `if`.
      TermsGate.fetchAcceptedVersion = () async => throw StateError('offline');

      await TermsGate.load();

      expect(TermsGate.acceptedVersion, isNull);
      expect(TermsGate.needsAcceptance, isTrue);
      expect(TermsGate.accepted.value, isFalse);
    });

    test('load does not rethrow — startup must not die on a failed check',
        () async {
      TermsGate.fetchAcceptedVersion = () async => throw StateError('offline');
      await expectLater(TermsGate.load(), completes);
    });

    test('a previously accepted device survives a load that throws', () async {
      // The other half of failing closed: closed for somebody who has never
      // agreed, open for somebody who has. Without this an aeroplane is a
      // lockout — accept, fail to reach the server, look at the terms again.
      await TermsGate.accept();
      TermsGate.reset();
      TermsGate.fetchAcceptedVersion = () async => throw StateError('offline');

      await TermsGate.load();

      expect(TermsGate.needsAcceptance, isFalse);
    });
  });

  group('scoping', () {
    test('the marker does not leak to the next account on the handset',
        () async {
      await TermsGate.accept();
      expect(TermsGate.needsAcceptance, isFalse);

      // Same phone, different person, and the server knows nothing about them.
      TermsGate.reset();
      TermsGate.currentAccount = () => 'user-b';
      TermsGate.fetchAcceptedVersion = () async => null;
      await TermsGate.load();

      expect(TermsGate.needsAcceptance, isTrue);
    });
  });

  group('accept', () {
    test('lets the user in even when the record cannot be filed', () async {
      TermsGate.recordAcceptance = (_) async => throw StateError('offline');

      await expectLater(TermsGate.accept(), throwsStateError);

      // The throw is the screen's cue to say the record did not land. It is
      // NOT a refusal: the local marker was written first, so the door is open.
      expect(TermsGate.needsAcceptance, isFalse);
    });

    test('re-files the record on the next load that reaches the server',
        () async {
      TermsGate.recordAcceptance = (_) async => throw StateError('offline');
      try {
        await TermsGate.accept();
      } catch (_) {}

      final filed = <int>[];
      TermsGate.recordAcceptance = (v) async => filed.add(v);
      TermsGate.fetchAcceptedVersion = () async => null;
      await TermsGate.load();

      expect(filed, [milesTermsVersion]);
    });
  });

  group('a local acceptance is never thrown away', () {
    // The defect: the old merge asked "is the server empty?", which is only
    // true for a first-ever acceptance. On every later version an offline
    // accept was discarded AND the local marker overwritten with the server's
    // lower number — so the user was re-gated forever and the device forgot
    // they had ever agreed.
    test('an offline accept of v2 survives a server that still says v1',
        () async {
      TermsGate.reset();
      final recorded = <int>[];
      TermsGate.currentAccount = () => 'uid-1';
      TermsGate.fetchAcceptedVersion = () async => 1;
      TermsGate.recordAcceptance = (v) async => recorded.add(v);
      SharedPreferences.setMockInitialValues({'miles_tos_v1_uid-1': 2});

      await TermsGate.load();

      expect(TermsGate.acceptedVersion, 2,
          reason: 'the higher of the two must win',);
      expect(recorded, contains(2),
          reason: 'the acceptance the server never got must be re-filed',);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('miles_tos_v1_uid-1'), 2,
          reason: 'the local marker must never be downgraded',);
    });

    test('a server ahead of the device wins and is written down', () async {
      TermsGate.reset();
      TermsGate.currentAccount = () => 'uid-1';
      TermsGate.fetchAcceptedVersion = () async => 3;
      TermsGate.recordAcceptance = (_) async {};
      SharedPreferences.setMockInitialValues({'miles_tos_v1_uid-1': 1});

      await TermsGate.load();

      expect(TermsGate.acceptedVersion, 3);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('miles_tos_v1_uid-1'), 3);
    });
  });

  test('the terms are flagged incomplete until the owner fills them in', () {
    // Not a style check. Shipping a compliance gate whose contact method is a
    // template token, incorporating a privacy policy that is not published, is
    // not a compliance artefact — and the two constants are easy to forget
    // precisely because the gate works without them.
    expect(milesContactEmail.contains('{{'), isFalse,
        reason: 'a template token must never reach a user',);
    expect(milesPrivacyPolicyUrl.contains('{{'), isFalse);
  });
}
