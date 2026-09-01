import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/vault/pin_pad.dart';
import 'package:miles/features/vault/vault_repository.dart';
import 'package:miles/features/vault/vault_screen.dart';
import 'package:miles/main.dart';

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
  String? _checkError;

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
    // The biometric sheet is a system window, so raising it sends this app
    // `inactive` — and auto-locking on that meant the vault re-locked itself
    // the instant it asked for a fingerprint. Unlocking by biometric could
    // never succeed. Same flag, and the same reason, as cover_gate.dart:107.
    if (MilesApp.authInProgress) return;
    // A picker or camera is a system window over our own app, not the user
    // leaving it. Locking on it disposed VaultScreen mid-pick and silently
    // discarded the files it was about to save.
    if (MilesApp.systemOverlayActive) return;
    // Auto-lock the moment the app leaves the foreground.
    if (state != AppLifecycleState.resumed && _unlocked) {
      setState(() => _unlocked = false);
    }
  }

  Future<void> _check() async {
    try {
      _hasPin = await VaultRepository.hasPin();
      _checkError = null;
    } catch (e) {
      // _hasPin stayed false, so _GateBody rendered "Create a vault PIN" at
      // someone who already has one and _onSetupPin would overwrite it.
      _checkError = friendlyAuthError(e);
    }
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
      if (mounted) {
        setState(() {
          _unlocked = true;
          MilesSound.cue(Cue.unlock);
          // Both of these, or the next lock re-renders the SETUP pad: it asked
          // "Confirm your PIN" out of nowhere, offered no biometrics, and — the
          // real problem — accepted ANY two matching digits as a new PIN and
          // opened the vault. An auto-lock that anyone can walk through is not
          // a lock.
          _hasPin = true;
          _firstPin = null;
          _message = null;
        });
      }
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
          MilesSound.cue(Cue.unlock);
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
      // Checked rather than assumed: biometricOnly on a handset with nothing
      // enrolled throws, and the old blanket catch reported that as
      // "unavailable" whatever the real reason was.
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      if (!supported) {
        if (mounted) {
          setState(() => _message = 'This phone has no screen lock set up.');
        }
        return;
      }

      MilesApp.authInProgress = true;
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock your private vault',
        options: AuthenticationOptions(
          // Falls back to the device PIN/pattern when no fingerprint or face is
          // enrolled, rather than throwing. biometricOnly made an unenrolled
          // phone look broken.
          biometricOnly: canCheck,
          stickyAuth: true,
        ),
      );
      MilesApp.authInProgress = false;
      if (ok && mounted) {
        setState(() => _unlocked = true);
        MilesSound.cue(Cue.unlock);
      }
    } on PlatformException catch (e) {
      MilesApp.authInProgress = false;
      if (!mounted) return;
      // The reason is the useful part. One message for every failure is how
      // this looked broken rather than merely unenrolled.
      setState(() => _message = switch (e.code) {
            'NotEnrolled' =>
              'No fingerprint or face is set up on this phone — use your PIN.',
            'NotAvailable' => 'Biometrics are not available — use your PIN.',
            'LockedOut' =>
              'Too many attempts. Wait a moment, or use your PIN.',
            'PermanentlyLockedOut' =>
              'Biometrics are locked. Unlock your phone first, or use your PIN.',
            _ => 'Biometrics failed (${e.code}) — use your PIN.',
          });
    } catch (e) {
      MilesApp.authInProgress = false;
      if (mounted) {
        setState(() => _message = 'Biometrics failed — use your PIN.');
      }
      debugPrint('[vault] biometric failed: ${e.runtimeType}');
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
              : _checkError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_checkError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: MilesColors.taupe, height: 1.5,),),
                        const SizedBox(height: 14),
                        TextButton(
                            onPressed: () {
                              setState(() => _loading = true);
                              _check();
                            },
                            child: const Text('Try again'),),
                      ],
                    ),
                  ),
                )
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
