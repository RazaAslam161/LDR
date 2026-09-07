import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One dead token, 131 refused pushes in fourteen days, and a handset that
/// believed it was registered the whole time: profiles.fcm_token is one slot
/// per account, nothing may null it server-side (a build-73 partner selects
/// the column whole, so a null is a presence oracle), and the client had no
/// way to learn its token was dead.
///
/// push_tokens (20260906140300) is the per-install ledger, reach-notify
/// addresses the UNION of it and the profiles slot so build 73 keeps working,
/// and the RPC answers `dead` so the handset can mint a fresh token.
String _code(String s) => s
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

String _fn(String src, String head) {
  final at = src.indexOf(head);
  expect(at, greaterThan(-1), reason: '$head not found');
  return src.substring(at, src.indexOf(RegExp(r'\n  \}\r?\n'), at));
}

void main() {
  final fcm = File('lib/core/services/fcm_service.dart').readAsStringSync();
  final repo = File('lib/core/data/supabase_repository.dart').readAsStringSync();
  final settings =
      File('lib/features/settings/settings_screen.dart').readAsStringSync();
  final fn = File('../supabase/functions/reach-notify/index.ts').readAsStringSync();
  final sql = File(
    '../supabase/migrations/'
    '20260906140300_a_push_token_belongs_to_a_device_not_an_account.sql',
  ).readAsStringSync();

  test('the install has an id of its own, minted once', () {
    final id = _fn(fcm, 'static Future<String> deviceId() async {');
    expect(id, contains('_deviceKey'));
    expect(fcm, contains("static const _deviceKey = 'push_device_id';"));
    expect(id, contains('Uuid().v4()'));
    expect(id, contains("kind: 'push-register'"),
        reason: 'a handset that cannot keep an id must say so',);
    // Never a hardware identifier: it survives a reinstall, which nothing here
    // needs, and it is a tell in a disguised app.
    expect(fcm, isNot(contains('ANDROID_ID')));
    expect(fcm, isNot(contains('androidId')));
  });

  test('registration goes through the RPC and heals a dead token', () {
    expect(repo, contains("_c.rpc<dynamic>(\n      'register_push_token'"));
    expect(repo, isNot(contains('setFcmToken')),
        reason: 'the profiles column is written by the definer now',);
    final save = _fn(fcm, 'static Future<void> _save(String token) async {');
    expect(save, contains('SupabaseRepository.registerPushToken'));
    expect(save, contains('deleteToken()'),
        reason: 'a token FCM refused is replaced, never re-uploaded',);
    expect(save, contains("kind: 'push-register'"));
    expect(save, contains('pushHealth.value'));
  });

  test('the 24h skip survives, so a resume costs no round trip', () {
    final reg = repo.substring(
      repo.indexOf('static Future<bool> registerPushToken('),
    );
    expect(reg.substring(0, 1400), contains("'fcm_token_written:\$uid'"));
    expect(reg.substring(0, 1400), contains('Duration(hours: 24)'));
  });

  test('sign-out revokes this install before the token is deleted', () {
    final forget = _fn(fcm, 'static Future<void> forgetDevice() async {');
    final revoke = forget.indexOf('revokePushToken');
    final delete = forget.indexOf('deleteToken');
    expect(revoke, greaterThan(-1));
    expect(revoke, lessThan(delete),
        reason: 'the row reach-notify reads goes first',);
    expect(forget, contains("kind: 'push-register'"));
    expect(repo, contains("'revoke_push_token'"));
  });

  test('signing out other devices revokes their tokens first', () {
    final out = _fn(repo, 'static Future<void> signOutOtherDevices(');
    final rpc = out.indexOf('revoke_other_push_tokens');
    final scope = out.indexOf('SignOutScope.others');
    expect(rpc, greaterThan(-1));
    expect(scope, greaterThan(-1));
    expect(rpc, lessThan(scope),
        reason: 'a revoked session holding a live token would still be rung',);
    expect(settings, contains('keepDeviceId: await FcmService.deviceId()'));
  });

  test('Settings names the reason this phone is not reachable', () {
    expect(settings, contains('valueListenable: pushHealth'));
    expect(settings, contains('PushHealth.blocked'));
    expect(settings, contains('PushHealth.noToken'));
    expect(_code(fcm), contains('final ValueNotifier<String?> pushHealth'));
  });

  test('reach-notify addresses every live install and the profiles slot', () {
    expect(fn, contains('.from("push_tokens")'));
    final union = fn.substring(fn.indexOf('const tokens = ['));
    expect(union.substring(0, 400), contains('new Set<string>'));
    expect(union.substring(0, 400), contains('recipient.fcm_token'),
        reason: 'build 73 owns no push_tokens row and must still be reached',);
    expect(fn, contains('for (const token of tokens) {'));
    // A dead token is revoked in the select-own ledger, never nulled on the
    // profile a build-73 partner can read.
    final failed = fn.substring(fn.indexOf('if (dead) {'));
    expect(failed.substring(0, 400), contains('revoked_reason: "unregistered"'));
    expect(fn, isNot(contains('fcm_token: null')));
  });

  test('signing out elsewhere never clears the kept phone\'s own token', () {
    // The first cut re-mirrored unconditionally, so an account whose ledger
    // had no row yet for THIS install had its working profiles token nulled
    // by the button whose dialog promises "This phone stays signed in".
    final fix = File(
      '../supabase/migrations/20260906140600_signing_out_elsewhere_'
      'must_not_silence_the_phone_in_your_hand.sql',
    ).readAsStringSync();
    final body = fix.substring(fix.indexOf('create or replace function'));
    final guard = body.indexOf('if v_keep is not null then');
    final write = body.indexOf('update public.profiles');
    expect(guard, greaterThan(-1));
    expect(guard, lessThan(write),
        reason: 'the profiles leg may be replaced, never erased, here',);
    expect(fix, contains('ROLLBACK'));
  });

  test('the migration keeps one live row per token and writes nothing else', () {
    expect(sql, contains('create unique index if not exists push_tokens_live_token_uidx'));
    expect(sql, contains('revoke all on public.push_tokens from anon, authenticated;'));
    expect(sql, contains('grant select on public.push_tokens to authenticated;'));
    expect(sql, contains("revoked_reason = 'claimed'"),
        reason: 'the 005300 cross-account invariant must hold on this ledger',);
    expect(sql, contains('ROLLBACK'));
  });
}
