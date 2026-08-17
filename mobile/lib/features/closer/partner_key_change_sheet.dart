import 'package:flutter/material.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/ui/theme.dart';

/// The human half of the key pin: the couple compares the safety code aloud
/// before this device accepts a changed partner key.
///
/// [PartnerKeyPin.check] refuses a changed key by throwing
/// [PartnerKeyChangedException], and this sheet is the only place outside the
/// rewrap ceremony allowed to answer it (partner_key_pin.dart names the two
/// callers of repin deliberately). Two exits and no third: "The codes match"
/// repins and resolves true so the caller can retry its load; "Not now"
/// resolves false and everything stays locked. The barrier does not dismiss —
/// a stray tap that read as an answer would either repin without a human or
/// bury the warning, and both are the silence the pin exists to refuse.
class PartnerKeyChangeSheet {
  PartnerKeyChangeSheet._();

  /// True only after the user said the codes match and the new key was pinned.
  static Future<bool> show(
    BuildContext context, {
    required String myUid,
    required PartnerKeyChangedException exception,
  }) async {
    // Computed before the dialog exists, so it never shows a loading state:
    // both inputs are already on this phone — the keystore keypair and the
    // fetched key the exception carries.
    final code = PartnerKeyPin.safetyCode(
      await CryptoCore.getMyPublicKeyB64(),
      exception.newKeyB64,
    );
    if (!context.mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _KeyChangeDialog(
        code: code,
        myUid: myUid,
        exception: exception,
      ),
    );
    return confirmed ?? false;
  }
}

class _KeyChangeDialog extends StatelessWidget {
  const _KeyChangeDialog({
    required this.code,
    required this.myUid,
    required this.exception,
  });

  final String code;
  final String myUid;
  final PartnerKeyChangedException exception;

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text(
          "Your partner's security key changed",
          style: TextStyle(color: MilesColors.cream50, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The usual reason is ordinary: they reinstalled the app or '
              'moved to a new phone, which makes a new key. The other reason '
              'is that someone is interfering with your connection. Nothing '
              'will decrypt or send until this is resolved.',
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
              'Compare this code aloud with your partner — they find theirs '
              'in Settings > Security code.',
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
            // The repin happens HERE, before the pop, so true never leaves
            // this dialog without the pin actually having moved — a caller
            // retrying on the strength of a write that had not happened yet
            // would meet the same mismatch again.
            onPressed: () async {
              await PartnerKeyPin.repin(
                myUid: myUid,
                partnerId: exception.partnerId,
                partnerPubB64: exception.newKeyB64,
              );
              if (context.mounted) Navigator.pop(context, true);
            },
            child: const Text('The codes match'),
          ),
        ],
      );
}
