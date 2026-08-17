import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/escrow_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The snooze arithmetic behind [EscrowPrompt.shouldAsk].
///
/// The once-ever decline flag left production with one escrow row for two
/// paired users: the dominant sign-up path never holds a password, so the
/// prompt is the only door and a single "Not now" welded it shut. These pin
/// the shape that replaced it — a decline holds a week, then only matters
/// while the account still has no escrow.
///
/// The preference keys are spelled out as literals on purpose: they are what
/// is actually on users' phones, and a rename here is a migration, not a
/// refactor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const declinedAtKey = 'escrow_prompt_declined_at_v1:test-uid';
  const legacyAskedKey = 'escrow_prompt_asked_v1';

  final now = DateTime(2026, 8, 17);
  Future<bool> missing() async => true;
  Future<bool> sealed() async => false;

  Future<SharedPreferences> prefsWith(Map<String, Object> values) {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  int msAgo(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  test('never asked and still missing asks', () async {
    final prefs = await prefsWith({});
    expect(
      await EscrowPrompt.shouldAsk(prefs, uid: 'test-uid', missing: missing, now: now),
      isTrue,
    );
  });

  test('a decline inside the week is silent', () async {
    final prefs =
        await prefsWith({declinedAtKey: msAgo(const Duration(days: 6))});
    expect(
      await EscrowPrompt.shouldAsk(prefs, uid: 'test-uid', missing: missing, now: now),
      isFalse,
    );
  });

  test('a decline expires after seven days while the escrow is missing',
      () async {
    final prefs =
        await prefsWith({declinedAtKey: msAgo(const Duration(days: 7))});
    expect(
      await EscrowPrompt.shouldAsk(prefs, uid: 'test-uid', missing: missing, now: now),
      isTrue,
    );
  });

  test('a sealed key is never asked about, however stale the decline',
      () async {
    // "Accepted" leaves no local mark at all — the escrow row itself is the
    // record — so this also covers the account that was backed up on another
    // path entirely, like a fresh sign-in.
    for (final values in [
      <String, Object>{},
      {declinedAtKey: msAgo(const Duration(days: 400))},
    ]) {
      final prefs = await prefsWith(values);
      expect(
        await EscrowPrompt.shouldAsk(prefs, uid: 'test-uid', missing: sealed, now: now),
        isFalse,
        reason: 'stored: $values',
      );
    }
  });

  test('the legacy once-ever flag becomes a decline made now', () async {
    final prefs = await prefsWith({legacyAskedKey: true});
    // Not re-asked on this launch — the flag was a real "Not now" once.
    expect(
      await EscrowPrompt.shouldAsk(prefs, uid: 'test-uid', missing: missing, now: now),
      isFalse,
    );
    // Migrated in place: dated as of this call, old flag gone.
    expect(prefs.getInt(declinedAtKey), now.millisecondsSinceEpoch);
    expect(prefs.getBool(legacyAskedKey), isNull);
    // And it is a snooze, not an exemption: a week later it asks again.
    expect(
      await EscrowPrompt.shouldAsk(
        prefs,
        uid: 'test-uid',
        missing: missing,
        now: now.add(const Duration(days: 7)),
      ),
      isTrue,
    );
  });
}
