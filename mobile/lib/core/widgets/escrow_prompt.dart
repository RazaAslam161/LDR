import 'package:flutter/material.dart';
import 'package:miles/core/data/key_escrow.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks, once, for the password needed to protect a user's encryption key.
///
/// Escrow can only be written where the password exists, and the password only
/// exists in memory at sign-in and sign-up. Every account that was already
/// signed in when escrow shipped therefore has none — and has no reason to ever
/// sign out, so it would never acquire one. Those are exactly the accounts that
/// lose every encrypted memory on their next reinstall.
///
/// Telling people to sign out and back in is a fix for two users, not for a
/// fleet. This is the migration for everyone else.
///
/// Deliberately dismissible and asked at most once per install. A modal the
/// user cannot escape, demanding a password on launch, is indistinguishable
/// from a phishing screen — and this app already trains people to be careful
/// about what asks them for credentials.
class EscrowPrompt {
  EscrowPrompt._();

  static const _askedKey = 'escrow_prompt_asked_v1';

  /// Show the prompt if this account has no escrow and has not been asked.
  static Future<void> maybeShow(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_askedKey) ?? false) return;
    if (!await KeyEscrow.isMissing()) return;
    if (!context.mounted) return;

    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => const _EscrowDialog(),
    );

    // Recorded whether or not they typed anything. Asking again on the next
    // launch turns a one-time migration into nagging.
    await prefs.setBool(_askedKey, true);

    if (password == null || password.isEmpty) return;
    await KeyEscrow.backup(password);
  }
}

class _EscrowDialog extends StatefulWidget {
  const _EscrowDialog();

  @override
  State<_EscrowDialog> createState() => _EscrowDialogState();
}

class _EscrowDialogState extends State<_EscrowDialog> {
  final _controller = TextEditingController();
  bool _obscured = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text(
          'Protect your memories',
          style: TextStyle(color: MilesColors.cream50, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reinstalling the app would currently make everything encrypted '
              'unreadable — your vault and memories. Confirming '
              'your password once stores a sealed copy of your key so that '
              "can't happen.\n\n"
              "We can't read it. It's locked with your password, which never "
              'leaves this phone.',
              style: TextStyle(color: MilesColors.taupe, height: 1.45,
                  fontSize: 13,),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              obscureText: _obscured,
              autofocus: true,
              style: const TextStyle(color: MilesColors.cream50),
              decoration: InputDecoration(
                hintText: 'Your password',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscured ? Icons.visibility_off : Icons.visibility,
                    color: MilesColors.taupe,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscured = !_obscured),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _controller.text),
            child: const Text('Protect'),
          ),
        ],
      );
}
