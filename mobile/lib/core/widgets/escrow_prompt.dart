import 'package:flutter/material.dart';
import 'package:miles/core/data/key_escrow.dart';
import 'package:miles/core/data/supabase_repository.dart';
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

    if (password == null || password.isEmpty) {
      // They said no, and that answer is recorded. Asking again on the next
      // launch turns a one-time migration into nagging.
      await prefs.setBool(_askedKey, true);
      return;
    }

    final failure = await _seal(password);
    // Only a real row counts as asked. A typo used to be recorded as one, so
    // the migration never came round again and the user was left believing
    // they were protected by something nobody alive can open.
    if (failure == null) await prefs.setBool(_askedKey, true);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failure ?? 'Your key is protected.')),
    );
  }

  /// Why it did not work, or null.
  ///
  /// Nothing here has ever checked what they typed, and nothing ever could
  /// afterwards — a wrap that opens for nobody looks exactly like a good one.
  /// The two failures are told apart because the answers differ: one is "type
  /// it again", the other is "we will ask you later".
  static Future<String?> _seal(String password) async {
    if (!await SupabaseRepository.reauthenticate(password)) {
      return "That isn't your password. Nothing was saved.";
    }
    if (!await KeyEscrow.backup(password)) {
      return "Couldn't save it just now. We'll ask again next time.";
    }
    return null;
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
