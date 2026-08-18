import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks the couple, once per key, to read their safety code to each other.
///
/// [PartnerKeyPin] remembers the partner's key on first sight and refuses every
/// later change until a human confirms it, which covers every substitution that
/// begins AFTER that first fetch. The one thing it cannot cover is the
/// substitution that begins AT it: a directory that hands back its own key the
/// very first time is pinned exactly as faithfully as the real one, and from
/// then on this device defends the imposter with the conviction it would have
/// spent on the partner. Nothing on the phone can tell those two first sights
/// apart — the pin has only one sample of the truth, and it is the sample under
/// suspicion. The two people can tell them apart in about ten seconds, by
/// checking that the twenty digits on one screen are the twenty digits on the
/// other.
///
/// The app has been able to show that code since the pin shipped, and has never
/// once asked anyone to compare it — so in practice nobody has. A check that
/// exists and is never taken protects nobody. This is the ask.
///
/// Dismissible, and re-asked after a week rather than never: the same bargain
/// the escrow prompt struck, for the same reasons. An unescapable modal on
/// launch teaches people to tap past security screens, and a once-ever flag
/// turns a single "Not now" into a permanent hole — which is exactly how escrow
/// coverage sat at one row for two paired users.
class SafetyCodePrompt {
  SafetyCodePrompt._();

  /// Epoch millis of the comparison, keyed by the account AND by a digest of
  /// the code that was compared.
  ///
  /// The code falls out of BOTH public keys, so this records precisely what a
  /// human confirmed — these digits, for this account — and any key rotation on
  /// either side lands on a key with no record and is asked about exactly once
  /// more. Scoping it to the partner's key alone would have been enough for the
  /// common rotations (their reinstall, their new phone) and wrong for the ones
  /// where MY key moves under a surviving prefs file: an escrow restore adopts
  /// the sealed seed on a device that has declared itself keyless, which
  /// changes my public key, changes the digits, and would otherwise inherit a
  /// verification for a code neither of them has ever seen.
  ///
  /// A digest rather than the digits for the same reason the pin stores a hash
  /// of the key rather than the key: nothing here needs to reproduce the code,
  /// only to recognise the one it was told about.
  static String _verifiedKey(String uid, String code) =>
      'safety_code_verified_v1:$uid:${_digest(code)}';

  /// Epoch millis of the last "Not now", per account — the handset is not the
  /// account, and a second sign-in on the same phone must not inherit the
  /// first's silence.
  ///
  /// Not scoped per key, deliberately: a rotation inside the snooze window is
  /// already met by the change sheet, which blocks everything until a human
  /// compares the code, so re-arming this one too would be a second ask for a
  /// question just answered.
  static String _declinedAtKey(String uid) =>
      'safety_code_declined_at_v1:$uid';

  /// How long a decline holds. Same week the escrow prompt uses — long enough
  /// that the answer was respected, short enough that "not right now, my
  /// partner is asleep" does not become never.
  static const _snooze = Duration(days: 7);

  static String _digest(String code) =>
      sha256.convert(utf8.encode(code)).toString();

  /// SharedPreferences, not the keystore the pin lives in, and the difference
  /// is honest: this is a record of a conversation, not a trust root. Forging
  /// it can only suppress a question the user can still ask any day from
  /// Settings; it can never make a key trusted. [PartnerKeyPin] alone decides
  /// that, out of secure storage.
  static Future<bool> _isVerifiedFor(String uid, String code) async =>
      (await SharedPreferences.getInstance()).getInt(_verifiedKey(uid, code)) !=
      null;

  /// Whether the unsolicited prompt may run, given what is stored.
  ///
  /// [code] is a callback rather than a value so the partner-key fetch is
  /// skipped entirely while snoozed — this runs on every launch, and most
  /// launches land inside the window. It answers null when there is no code to
  /// compare (no published key yet, or the fetch did not land), which is not an
  /// answer to the question and must not be scored as one.
  @visibleForTesting
  static Future<bool> shouldAsk(
    SharedPreferences prefs, {
    required String uid,
    required Future<String?> Function() code,
    DateTime? now,
  }) async {
    final declinedAt = prefs.getInt(_declinedAtKey(uid));
    if (declinedAt != null &&
        (now ?? DateTime.now())
                .difference(DateTime.fromMillisecondsSinceEpoch(declinedAt)) <
            _snooze) {
      return false;
    }
    final current = await code();
    if (current == null) return false;
    return prefs.getInt(_verifiedKey(uid, current)) == null;
  }

  /// The ONLY writer of a verification, and it is only ever called from a
  /// button a person pressed. There is deliberately no path that marks a key
  /// verified on the user's behalf — a verification nobody performed is worse
  /// than none, because the Settings row then says the check was done.
  @visibleForTesting
  static Future<void> record(
    SharedPreferences prefs, {
    required String uid,
    required String code,
    DateTime? now,
  }) =>
      prefs.setInt(
        _verifiedKey(uid, code),
        (now ?? DateTime.now()).millisecondsSinceEpoch,
      );

  /// Show the prompt if this couple has never compared the code these two keys
  /// produce, and the account is not snoozed.
  static Future<void> maybeShow(
    BuildContext context, {
    required String? partnerId,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null || partnerId == null) return;
    final prefs = await SharedPreferences.getInstance();
    String? code;
    final ask = await shouldAsk(
      prefs,
      uid: uid,
      code: () async => code = await _fetchCode(partnerId),
    );
    final current = code;
    if (!ask || current == null || !context.mounted) return;
    // The launch prompts fire in parallel and this is the least urgent of them,
    // so it stands down rather than landing on top of escrow or the App-Lock
    // nudge. Standing down does NOT spend the ask: nothing is recorded here,
    // and the next launch tries again.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final matched = await showDialog<bool>(
          context: context,
          builder: (_) => _SafetyCodeDialog(code: current),
        ) ??
        false;
    if (matched) {
      await record(prefs, uid: uid, code: current);
    } else {
      // Everything that is not a person saying the digits matched is a
      // decline — "Not now", the back button, a tap on the barrier. A week,
      // then the question comes back while it is still unanswered.
      await prefs.setInt(
        _declinedAtKey(uid),
        DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  /// Record a comparison the user made somewhere else in the app.
  ///
  /// The change sheet already puts the couple through this exact comparison
  /// when a key rotates, and its "The codes match" is the same person saying
  /// the same thing about the same digits. Without this, the phone that had
  /// just been walked through a key change would be asked to compare the new
  /// key again on the next launch, which reads as the app forgetting.
  static Future<void> recordVerified({
    required String myUid,
    required String partnerPubB64,
  }) async {
    final code = PartnerKeyPin.safetyCode(
      await CryptoCore.getMyPublicKeyB64(),
      partnerPubB64,
    );
    await record(
      await SharedPreferences.getInstance(),
      uid: myUid,
      code: code,
    );
  }

  /// Whether this account has ever compared the code the two CURRENT keys
  /// produce — for the Settings row's subtitle.
  ///
  /// Null when there is nothing to answer with: no partner, no published key,
  /// or the fetch did not land. "Not compared" is a claim about the couple, and
  /// an unreachable directory is not evidence for it.
  static Future<bool?> isVerified(String? partnerId) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null || partnerId == null) return null;
    final code = await _fetchCode(partnerId);
    if (code == null) return null;
    return _isVerifiedFor(uid, code);
  }

  /// The twenty digits for the CURRENT pair of keys, or null when there are
  /// not two keys to build them from.
  ///
  /// The published key, exactly as the Settings dialog reads it and not the
  /// pinned digest — a substituted directory key is the thing this whole
  /// prompt exists to surface, so the code shown has to be the one the
  /// directory is actually serving.
  static Future<String?> _fetchCode(String partnerId) async {
    try {
      final partnerPub =
          await SupabaseRepository.fetchPartnerPublicKey(partnerId);
      if (partnerPub == null || partnerPub == CryptoCore.legacyPublicKey) {
        return null;
      }
      return PartnerKeyPin.safetyCode(
        await CryptoCore.getMyPublicKeyB64(),
        partnerPub,
      );
    } catch (e) {
      // Logged, not swallowed silently, and it answers null rather than
      // false — offline is not "already verified", and it must not spend the
      // one ask this account gets for this key.
      debugPrint('safety code prompt: could not fetch partner key: $e');
      return null;
    }
  }
}

class _SafetyCodeDialog extends StatelessWidget {
  const _SafetyCodeDialog({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        // Twenty digits plus the reason for them is more text than the change
        // sheet carries, and a phone at 1.3x font scale is not an edge case in
        // a fleet — this dialog scrolls rather than striping.
        scrollable: true,
        title: const Text(
          'Compare your security code',
          style: TextStyle(color: MilesColors.cream50, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These digits are built from both of your keys. If your partner '
              'sees the same twenty digits, the two of you are connected to '
              'each other and to nothing in between.',
              style: TextStyle(
                color: MilesColors.taupe,
                height: 1.45,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                code,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.5,
                  height: 1.4,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Read them aloud once — theirs are in Settings > Security code. '
              'After this the app watches the key itself and stops to tell you '
              'if it ever changes; only the first check needs the two of you. '
              'If the codes are different, talk about it before sending '
              'anything private.',
              style: TextStyle(
                color: MilesColors.taupe,
                height: 1.45,
                fontSize: 13,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('They match'),
          ),
        ],
      );
}
