import 'package:flutter/material.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/vault/pin_pad.dart';
import 'package:miles/features/vault/vault_repository.dart';

/// Changing the vault PIN: current, new, confirm.
///
/// The vault could be given a PIN once and never re-keyed — there was no screen
/// for it and no server verb behind one. `change_vault_pin` is that verb, and
/// this is the only thing that calls it.
///
/// **All three PINs are collected before anything is sent.** Not for tidiness:
/// checking the current PIN up front would spend one of the five attempts
/// before the user has even chosen a new PIN, so mistyping the confirmation
/// would cost an attempt on a PIN that was correct. One call, at the end,
/// checks and re-keys together.
class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key});

  static Future<bool?> open(BuildContext context) =>
      Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => const ChangePinScreen(),
      ),);

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

enum _Step { current, fresh, confirm }

class _ChangePinScreenState extends State<ChangePinScreen> {
  _Step _step = _Step.current;
  String? _current;
  String? _fresh;
  String? _message;
  bool _busy = false;

  /// Rebuilds [PinPad] between steps so its filled dots clear. The gate screen
  /// drives its two-step setup the same way.
  int _padKey = 0;

  /// Bumped to shake the pad and clear it in place, without remounting.
  int _errorSignal = 0;

  void _fail(String message, {_Step? back}) {
    setState(() {
      _message = message;
      _errorSignal++;
      if (back != null) {
        _step = back;
        _padKey++;
        if (back == _Step.current) {
          _current = null;
          _fresh = null;
        } else if (back == _Step.fresh) {
          _fresh = null;
        }
      }
    });
  }

  Future<void> _onComplete(String pin) async {
    switch (_step) {
      case _Step.current:
        setState(() {
          _current = pin;
          _step = _Step.fresh;
          _message = null;
          _padKey++;
        });
      case _Step.fresh:
        if (pin == _current) {
          // Caught here rather than sent: the server would accept it and
          // report success, and the user would be told their PIN changed when
          // nothing about it had. No secret is revealed by saying so — they
          // typed both halves themselves.
          _fail('That is already your PIN.', back: _Step.fresh);
          return;
        }
        setState(() {
          _fresh = pin;
          _step = _Step.confirm;
          _message = null;
          _padKey++;
        });
      case _Step.confirm:
        if (pin != _fresh) {
          _fail("Those didn't match — choose a new PIN again.",
              back: _Step.fresh,);
          return;
        }
        await _submit();
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final verdict = await VaultRepository.changePin(_current!, _fresh!);
      if (!mounted) return;
      switch (verdict) {
        case 'ok':
          MilesSound.cue(Cue.unlock);
          Navigator.of(context).pop(true);
        case 'wrong':
          _fail('That was not your current PIN.', back: _Step.current);
        case 'locked':
          _fail('Too many tries. Locked for 15 minutes.',
              back: _Step.current,);
        case 'no_pin':
          // Nothing to change. Reachable only if the PIN was removed by
          // another device between opening this screen and submitting it.
          _fail('This vault has no PIN yet.', back: _Step.current);
        default:
          _fail('Could not change the PIN.', back: _Step.current);
      }
    } catch (e) {
      if (!mounted) return;
      _fail(_errorText(e), back: _Step.current);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The gate screen's taxonomy, plus the two verdicts only this screen can
  /// receive. A server that has not run the migration yet answers with a
  /// missing-function error, and telling the user to "try again" forever is
  /// the failure mode that costs a support conversation.
  String _errorText(Object e) {
    final s = e.toString();
    if (s.contains('invalid_pin')) return 'PIN must be exactly 4 digits.';
    if (s.contains('not_authenticated')) return 'Please sign in again.';
    if (s.contains('locked')) return 'Too many tries. Locked for 15 minutes.';
    if (s.contains('change_vault_pin') || s.contains('does not exist')) {
      return 'This needs a server update before it will work.';
    }
    return 'Could not change the PIN. Please try again.';
  }

  String get _title => switch (_step) {
        _Step.current => 'Enter your current PIN',
        _Step.fresh => 'Choose a new PIN',
        _Step.confirm => 'Confirm your new PIN',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Change vault PIN'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            Text(
              _title,
              style: const TextStyle(
                  color: MilesColors.cream50, fontSize: 16,),
            ),
            const SizedBox(height: 8),
            // Reserved whether or not there is a message, so the pad does not
            // jump up the screen the first time something goes wrong.
            SizedBox(
              height: 20,
              child: _message == null
                  ? null
                  : Text(
                      _message!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: MilesColors.blush, fontSize: 13,),
                    ),
            ),
            const SizedBox(height: 12),
            PinPad(
              key: ValueKey(_padKey),
              enabled: !_busy,
              errorSignal: _errorSignal,
              onComplete: _onComplete,
            ),
            const Spacer(),
            SizedBox(
              height: 24,
              child: _busy
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
