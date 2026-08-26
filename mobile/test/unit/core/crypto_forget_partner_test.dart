import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/data/crypto_core.dart';

/// Unpair had no key primitive of its own. Between forgetAccount() — the
/// sign-out hammer, which drops the account's own keypair and resets the
/// rewrap gate — and doing nothing at all, there was no third option, so
/// unpair took the second one and the ex-couple's shared key stayed live for
/// the rest of the process.
///
/// forgetPartner() is that third option. What it must NOT do is as load-bearing
/// as what it must.
void main() {
  test('forgetPartner bumps the key epoch', () {
    // The bump is the half that is easy to drop and impossible to notice: null
    // the shared key alone and the plaintext caches keyed on the old epoch go
    // on serving bytes decrypted under the ex-couple's key.
    final before = CryptoCore.keyEpoch.value;
    CryptoCore.forgetPartner();
    expect(CryptoCore.keyEpoch.value, greaterThan(before));
  });

  test('forgetPartner leaves the rewrap gate alone', () {
    // `keyless` answers a question about THIS account's own seed, and the
    // /rewrap route reads it. forgetAccount() resets it because the account is
    // going; a breakup must not, or a genuine rewrap-needed state disappears
    // behind it and the user is silently left unable to read their history.
    CryptoCore.keyless.value = true;
    CryptoCore.forgetPartner();
    expect(CryptoCore.keyless.value, isTrue);
    CryptoCore.keyless.value = false;
  });

  test('forgetPartner does not touch this account own key material', () {
    // Structural, not behavioural: exportVaultKeyBytes reads the seed from the
    // platform keystore, which a plain unit test has no access to — the same
    // limitation crypto_core_test.dart and vault_key_test.dart both document.
    //
    // What that makes provable here is the thing that actually matters: the
    // vault key is HKDF(own seed, 'miles-vault-v1'), so it survives a breakup
    // as long as this method leaves the seed and the keypair alone. A stale
    // audit finding claims leaving "permanently destroys your own Private
    // Vault"; it described the dead vault_items table, and the confirmation
    // copy must never repeat it.
    final src = File('lib/core/data/crypto_core.dart').readAsStringSync();
    final start = src.indexOf('static void forgetPartner() {');
    final end = src.indexOf('}', start);
    expect(start, greaterThan(-1), reason: 'forgetPartner has gone');
    final body = src.substring(start, end);
    for (final field in ['_vaultKey', '_myKeyPair', '_accountId', 'keyless']) {
      expect(body.contains(field), isFalse,
          reason: '$field belongs to the account, which is still signed in');
    }
    expect(body.contains('_sharedKey'), isTrue);
    expect(body.contains('_ring'), isTrue);
    expect(body.contains('_bumpEpoch()'), isTrue);
  });
}
