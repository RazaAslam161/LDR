import 'package:flutter/material.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/ui/theme.dart';

/// The standing home of the couple's safety code: Settings > Security code.
///
/// The key-change sheet shows the code once, on the phone that noticed a
/// change; this dialog is where the OTHER phone finds the same twenty digits
/// to read back — and where either of them can look on any ordinary day.
/// [PartnerKeyPin.safetyCode] sorts the two keys before hashing, so both
/// phones compute the identical string without agreeing who goes first.
///
/// [partnerId] is nullable because the row is reachable before pairing; the
/// no-partner and never-opened-Closer states get a plain sentence each, never
/// a throw — this dialog only reads, so nothing here is worth an error state
/// that looks like the encryption itself failing.
Future<void> showSecurityCodeDialog(
  BuildContext context, {
  required String? partnerId,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SecurityCodeDialog(partnerId: partnerId),
    );

class _SecurityCodeDialog extends StatefulWidget {
  const _SecurityCodeDialog({required this.partnerId});

  final String? partnerId;

  @override
  State<_SecurityCodeDialog> createState() => _SecurityCodeDialogState();
}

class _SecurityCodeDialogState extends State<_SecurityCodeDialog> {
  bool _loading = true;
  String? _code;
  String? _message;

  @override
  void initState() {
    super.initState();
    final partnerId = widget.partnerId;
    if (partnerId == null) {
      // Decided before the first build, no setState needed: there is nothing
      // to fetch and nothing to wait for.
      _loading = false;
      _message = 'Link your partner first — the code belongs to the two '
          'of you.';
    } else {
      _load(partnerId);
    }
  }

  Future<void> _load(String partnerId) async {
    try {
      // The PUBLISHED key, the same one every derive checks against the pin —
      // deliberately not the pinned digest, so a substituted directory key
      // shows up HERE as two phones reading different codes.
      final partnerPub =
          await SupabaseRepository.fetchPartnerPublicKey(partnerId);
      if (partnerPub == null || partnerPub == CryptoCore.legacyPublicKey) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _message = "Your partner hasn't opened Closer yet, so there is no "
              'code to compare. Ask them to open it once.';
        });
        return;
      }
      final code = PartnerKeyPin.safetyCode(
        await CryptoCore.getMyPublicKeyB64(),
        partnerPub,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _code = code;
      });
    } catch (e) {
      // Surfaced, not swallowed: the sentence on screen says the check did
      // not run, and the log keeps the actual failure.
      debugPrint('security code: could not fetch partner key: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _message = "Couldn't check just now. Try again when you're online.";
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text(
          'Security code',
          style: TextStyle(color: MilesColors.cream50, fontSize: 18),
        ),
        content: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_message != null)
                    Text(
                      _message!,
                      style: const TextStyle(
                        color: MilesColors.taupe,
                        height: 1.45,
                        fontSize: 13,
                      ),
                    )
                  else ...[
                    Center(
                      child: Text(
                        _code!,
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
                    const SizedBox(height: 16),
                    const Text(
                      'You and your partner see the same code when nobody is '
                      'interfering. Compare it aloud any time.',
                      style: TextStyle(
                        color: MilesColors.taupe,
                        height: 1.45,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
}
