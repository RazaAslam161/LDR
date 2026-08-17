import 'package:flutter/material.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/vault/pin_pad.dart';

/// Set a new 4-digit app-lock PIN (enter, then confirm). Returns true if set.
Future<bool> showAppLockPinSetup(BuildContext context) async {
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: MilesColors.surface1,
        builder: (ctx) => const _PinSheet(mode: _PinMode.setup),
      ) ??
      false;
}

/// Verify the existing app-lock PIN. Returns true if correct.
Future<bool> showAppLockPinVerify(BuildContext context) async {
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: MilesColors.surface1,
        builder: (ctx) => const _PinSheet(mode: _PinMode.verify),
      ) ??
      false;
}

enum _PinMode { setup, verify }

class _PinSheet extends StatefulWidget {
  const _PinSheet({required this.mode});
  final _PinMode mode;

  @override
  State<_PinSheet> createState() => _PinSheetState();
}

class _PinSheetState extends State<_PinSheet> {
  String? _firstPin;
  int _errorSignal = 0;
  int _padKey = 0;
  String? _message;

  Future<void> _onComplete(String pin) async {
    if (widget.mode == _PinMode.verify) {
      if (await AppLock.verifyPin(pin)) {
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() {
          _message = 'Wrong PIN';
          _errorSignal++;
        });
      }
      return;
    }
    // setup
    if (_firstPin == null) {
      setState(() {
        _firstPin = pin;
        _message = 'Confirm your PIN';
        _padKey++;
      });
      return;
    }
    if (pin != _firstPin) {
      setState(() {
        _firstPin = null;
        _message = "Those didn't match — try again";
        _errorSignal++;
        _padKey++;
      });
      return;
    }
    // The write goes to the keystore now, which can refuse where prefs never
    // did — and a sheet that closes as if it saved is a PIN the user believes
    // in and the phone has never heard of.
    try {
      await AppLock.setPin(pin);
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = "Couldn't save that PIN — try again";
          _errorSignal++;
          _padKey++;
          _firstPin = null;
        });
      }
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final setup = widget.mode == _PinMode.setup;
    final title = setup
        ? (_firstPin == null ? 'Set an app-lock PIN' : 'Confirm your PIN')
        : 'Enter your app-lock PIN';
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: const TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,),),
          const SizedBox(height: 6),
          Text(
            _message ??
                (setup
                    ? 'A 4-digit PIN that always lets you in.'
                    : 'Confirm to continue.'),
            textAlign: TextAlign.center,
            style: TextStyle(
                color: _message == 'Wrong PIN' ||
                        _message == "Those didn't match — try again"
                    ? MilesColors.blush
                    : MilesColors.taupe,
                fontSize: 13,),
          ),
          const SizedBox(height: 16),
          PinPad(
            key: ValueKey(_padKey),
            errorSignal: _errorSignal,
            onComplete: _onComplete,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: MilesColors.taupe),),
          ),
        ],
      ),
    );
  }
}
