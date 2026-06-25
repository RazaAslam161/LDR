import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/vault/pin_pad.dart';

/// Full-screen lock shown over the app while [AppLock.locked] is true. Always
/// offers a way in: it auto-prompts biometrics, lets you retry that prompt, and
/// falls back to the 4-digit app-lock PIN. Cannot be dismissed without auth.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  List<BiometricType> _bio = const [];
  bool _hasPin = false;
  bool _showPin = false;
  bool _busy = false;
  int _errorSignal = 0;
  String? _message;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bio = await AppLock.availableBiometrics();
    final hasPin = await AppLock.hasPin();
    if (!mounted) return;
    setState(() {
      _bio = bio;
      _hasPin = hasPin;
      // No biometrics enrolled → straight to the PIN.
      _showPin = bio.isEmpty && hasPin;
    });
    if (bio.isNotEmpty) _authenticate();
  }

  Future<void> _authenticate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final ok = await AppLock.authenticate();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) {
        _message = _hasPin ? 'Try again, or use your PIN' : 'Try again';
      }
    });
  }

  Future<void> _onPin(String pin) async {
    final ok = await AppLock.verifyPin(pin);
    if (!mounted) return;
    if (ok) {
      AppLock.unlock();
    } else {
      setState(() {
        _message = 'Wrong PIN';
        _errorSignal++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = AppLock.biometricLabel(_bio);
    final hasBio = _bio.isNotEmpty;
    final faceIcon = label.startsWith('Face');
    return Positioned.fill(
      child: PopScope(
        canPop: false,
        child: Material(
          color: MilesColors.night,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_rounded,
                        color: MilesColors.ember, size: 52),
                    const SizedBox(height: 14),
                    const Text('Tethered is locked',
                        style: TextStyle(
                            color: MilesColors.cream50,
                            fontSize: 19,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(_message ?? 'Unlock to continue',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: _message == 'Wrong PIN'
                                ? MilesColors.blush
                                : MilesColors.taupe,
                            fontSize: 13)),
                    const SizedBox(height: 28),
                    if (!_showPin) ...[
                      if (hasBio)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: MilesColors.ember,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 28, vertical: 14),
                          ),
                          onPressed: _busy ? null : _authenticate,
                          icon: Icon(faceIcon
                              ? Icons.face_rounded
                              : Icons.fingerprint),
                          label: Text('Unlock with $label'),
                        ),
                      if (_hasPin)
                        TextButton(
                          onPressed: () => setState(() => _showPin = true),
                          child: const Text('Use PIN instead',
                              style: TextStyle(color: MilesColors.gilt)),
                        ),
                      if (!hasBio && !_hasPin)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: MilesColors.ember),
                          onPressed: _busy ? null : _authenticate,
                          icon: const Icon(Icons.lock_open),
                          label: const Text('Unlock'),
                        ),
                    ] else ...[
                      PinPad(
                        key: ValueKey(_errorSignal),
                        errorSignal: _errorSignal,
                        onComplete: _onPin,
                      ),
                      if (hasBio)
                        TextButton.icon(
                          onPressed: () {
                            setState(() => _showPin = false);
                            _authenticate();
                          },
                          icon: Icon(
                              faceIcon ? Icons.face_rounded : Icons.fingerprint,
                              color: MilesColors.gilt,
                              size: 18),
                          label: Text('Use $label',
                              style: const TextStyle(color: MilesColors.gilt)),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
