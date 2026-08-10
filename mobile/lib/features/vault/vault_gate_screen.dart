import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/vault/pin_pad.dart';
import 'package:miles/features/vault/vault_repository.dart';
import 'package:miles/features/vault/vault_screen.dart';

/// Guards the Private Vault. On first use it sets a 4-digit PIN; thereafter it
/// asks for the PIN (or biometric) every time. Auto-locks when backgrounded.
class VaultGateScreen extends StatefulWidget {
  const VaultGateScreen({super.key});

  @override
  State<VaultGateScreen> createState() => _VaultGateScreenState();
}

class _VaultGateScreenState extends State<VaultGateScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _hasPin = false;
  bool _unlocked = false;
  bool _busy = false;

  // Setup flow
  String? _firstPin;

  int _padKey = 0; // bump to reset the pad (no shake)
  int _errorSignal = 0; // bump to shake the pad
  String? _message;

  final _auth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Auto-lock the moment the app leaves the foreground.
    if (state != AppLifecycleState.resumed && _unlocked) {
      setState(() => _unlocked = false);
    }
  }

  Future<void> _check() async {
    try {
      _hasPin = await VaultRepository.hasPin();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _onSetupPin(String pin) async {
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
      });
      return;
    }
    setState(() => _busy = true);
    try {
      await VaultRepository.setPin(pin);
      if (mounted) setState(() => _unlocked = true);
    } catch (e, st) {
      // Surface the real error (logged) instead of a blanket generic message.
      debugPrint('Vault setPin failed: $e\n$st');
      setState(() {
        _message = _pinErrorText(e);
        _firstPin = null;
        _errorSignal++;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _pinErrorText(Object e) {
    final s = e.toString();
    if (s.contains('invalid_pin')) return 'PIN must be exactly 4 digits.';
    if (s.contains('not_authenticated')) return 'Please sign in again.';
    if (s.contains('gen_salt') || s.contains('does not exist')) {
      return 'Server PIN setup error — please update the app.';
    }
    return 'Could not set the PIN. Please try again.';
  }

  Future<void> _onEnterPin(String pin) async {
    setState(() => _busy = true);
    try {
      final result = await VaultRepository.verifyPin(pin);
      if (!mounted) return;
      switch (result) {
        case 'ok':
          setState(() => _unlocked = true);
        case 'locked':
          setState(() {
            _message = 'Too many tries. Locked for 15 minutes.';
            _errorSignal++;
          });
        case 'no_pin':
          setState(() => _hasPin = false);
        default: // 'wrong'
          setState(() {
            _message = 'Wrong PIN';
            _errorSignal++;
          });
      }
    } catch (e, st) {
      debugPrint('Vault verifyPin failed: $e\n$st');
      setState(() {
        _message = "Couldn't check the PIN";
        _errorSignal++;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _biometric() async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock your private vault',
        options: const AuthenticationOptions(biometricOnly: true),
      );
      if (ok && mounted) setState(() => _unlocked = true);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Biometrics unavailable — use your PIN');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) {
      return VaultScreen(onLock: () => setState(() => _unlocked = false));
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EmberBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _GateBody(
                  setup: !_hasPin,
                  confirming: _firstPin != null,
                  message: _message,
                  busy: _busy,
                  padKey: _padKey,
                  errorSignal: _errorSignal,
                  hasPin: _hasPin,
                  onPin: _hasPin ? _onEnterPin : _onSetupPin,
                  onBiometric: _biometric,
                  onBack: () => Navigator.of(context).maybePop(),
                ),
        ),
      ),
    );
  }
}

class _GateBody extends StatelessWidget {
  const _GateBody({
    required this.setup,
    required this.confirming,
    required this.message,
    required this.busy,
    required this.padKey,
    required this.errorSignal,
    required this.hasPin,
    required this.onPin,
    required this.onBiometric,
    required this.onBack,
  });

  final bool setup;
  final bool confirming;
  final String? message;
  final bool busy;
  final int padKey;
  final int errorSignal;
  final bool hasPin;
  final ValueChanged<String> onPin;
  final VoidCallback onBiometric;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final title = setup
        ? (confirming ? 'Confirm your PIN' : 'Create a vault PIN')
        : 'Vault';
    final subtitle = setup
        ? 'A 4-digit PIN protects what only you can see.'
        : 'Your partner can never open this.';
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: MilesColors.cream50),
            onPressed: onBack,
          ),
        ),
        const Spacer(),
        const Icon(Icons.lock_outline, color: MilesColors.blush, size: 40),
        const SizedBox(height: 16),
        Text(title, style: Theme.of(context).textTheme.displaySmall),
        const SizedBox(height: 8),
        Text(subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: MilesColors.taupe),),
        const SizedBox(height: 12),
        SizedBox(
          height: 20,
          child: message == null
              ? null
              : Text(message!,
                  style: const TextStyle(color: MilesColors.blush, fontSize: 13),),
        ),
        const SizedBox(height: 12),
        PinPad(
          key: ValueKey(padKey),
          errorSignal: errorSignal,
          enabled: !busy,
          onComplete: onPin,
        ),
        const SizedBox(height: 12),
        if (hasPin)
          TextButton.icon(
            onPressed: onBiometric,
            icon: const Icon(Icons.fingerprint, color: MilesColors.gilt),
            label: const Text('Use biometrics',
                style: TextStyle(color: MilesColors.gilt),),
          ),
        const Spacer(),
      ],
    );
  }
}
