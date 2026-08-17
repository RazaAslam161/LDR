import 'package:flutter/material.dart';
import 'package:miles/core/data/key_escrow.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks for the password needed to protect a user's encryption key.
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
/// Deliberately dismissible, and re-asked after a week rather than never.
/// "At most once per install" was the first design, and production showed what
/// a single "Not now" costs under it: one escrow row for two paired users,
/// because the dominant sign-up path (email confirmation) never holds a
/// password long enough to seal anything, so this prompt is the only door —
/// and it welded itself shut. A modal the user cannot escape, demanding a
/// password on launch, is still indistinguishable from a phishing screen, so
/// declining stays cheap; it just stops being permanent while the account
/// still has everything to lose.
class EscrowPrompt {
  EscrowPrompt._();

  /// The retired once-ever flag. Still read so an install that said "Not now"
  /// under the old scheme starts a fresh week of snooze, rather than being
  /// re-asked on this very launch or written off forever.
  static const _askedKey = 'escrow_prompt_asked_v1';

  /// Epoch milliseconds of the last "Not now" — scoped per account, because
  /// the handset is not the account: a second sign-in on the same phone must
  /// not inherit the first account's snooze. (The legacy flag above predates
  /// this and stays device-wide; it is migrated into whichever account trips
  /// over it first, which is the account it was almost certainly written by.)
  static String _declinedAtKey(String uid) =>
      'escrow_prompt_declined_at_v1:$uid';

  /// How long a decline holds. Long enough that the answer was respected,
  /// short enough that an account a reinstall would wipe is not left exposed
  /// for a lifetime on the strength of one tap.
  static const _snooze = Duration(days: 7);

  /// Whether the unsolicited prompt may run, given what is stored.
  ///
  /// [missing] is a callback rather than a value so the server lookup is
  /// skipped entirely while snoozed — this runs on every launch, and most
  /// launches land inside the window. An account whose key actually got
  /// sealed answers false there and is never asked again, whatever the
  /// timestamps say.
  @visibleForTesting
  static Future<bool> shouldAsk(
    SharedPreferences prefs, {
    required String uid,
    required Future<bool> Function() missing,
    DateTime? now,
  }) async {
    final declinedAt = prefs.getInt(_declinedAtKey(uid));
    if (declinedAt == null && (prefs.getBool(_askedKey) ?? false)) {
      // The old flag says only that the question was answered, not when.
      // Treating it as a decline made just now is the one reading that
      // neither nags on this very launch nor honours a months-old "Not now"
      // forever.
      await prefs.setInt(
        _declinedAtKey(uid),
        (now ?? DateTime.now()).millisecondsSinceEpoch,
      );
      await prefs.remove(_askedKey);
      return false;
    }
    if (declinedAt != null &&
        (now ?? DateTime.now())
                .difference(DateTime.fromMillisecondsSinceEpoch(declinedAt)) <
            _snooze) {
      return false;
    }
    return missing();
  }

  /// Show the prompt if this account has no escrow and is not snoozed.
  static Future<void> maybeShow(BuildContext context) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await shouldAsk(prefs, uid: uid, missing: KeyEscrow.isMissing)) {
      return;
    }
    if (!context.mounted) return;

    if (await show(context)) {
      // They said no, and that answer is recorded — with a date, so it can
      // expire. Asking again next launch is nagging; never asking again is
      // how coverage sat at one row for two paired users.
      await prefs.setInt(
        _declinedAtKey(uid),
        DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  /// Run the dialog and, when a password is offered, seal the key under it.
  /// True when the user declined.
  ///
  /// A failed seal is not a decline: the snackbar has already said whether it
  /// was a typo or the server, and either way the question stays live for the
  /// next launch. Settings calls this directly, without the snooze check —
  /// opening the flow yourself is not being nagged.
  static Future<bool> show(BuildContext context) async {
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => const _EscrowDialog(),
    );
    if (password == null || password.isEmpty) return true;

    final failure = await _seal(password);
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failure ?? 'Your key is protected.')),
    );
    return false;
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
              onSubmitted: (v) {
                if (v.isNotEmpty) Navigator.pop(context, v);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            // Disabled while empty. An empty "Protect" used to pop exactly
            // like "Not now" and buy a week of snooze — a mis-tap scored as
            // an answer.
            builder: (_, value, __) => FilledButton(
              onPressed: value.text.isEmpty
                  ? null
                  : () => Navigator.pop(context, _controller.text),
              child: const Text('Protect'),
            ),
          ),
        ],
      );
}
