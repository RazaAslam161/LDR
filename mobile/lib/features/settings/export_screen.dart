import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/data_export_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/features/vault/pin_pad.dart';
import 'package:miles/features/vault/vault_repository.dart';
import 'package:miles/main.dart' show MilesApp;
import 'package:wakelock_plus/wakelock_plus.dart';

/// Export everything the couple keeps here into a folder the user picks.
///
/// The app positions itself as the container for a couple's entire history;
/// until this screen, the only way that history left was the delete button.
/// E2EE means only this device can ever build the export, so the run happens
/// here in the foreground — the honest v1. What each choice costs is said out
/// loud: the copy is unencrypted, the vault wants its own PIN, and leaving
/// the screen stops the run.
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

enum _Phase { setup, running, done }

class _ExportScreenState extends ConsumerState<ExportScreen> {
  // Everything but the vault, which is opt-in behind its PIN — the same
  // posture the vault itself has everywhere else in the app.
  final Set<ExportModule> _selected = {
    ExportModule.profile,
    ExportModule.chat,
    ExportModule.gallery,
    ExportModule.memories,
    ExportModule.wishJar,
  };

  static const _needsCouple = {
    ExportModule.chat,
    ExportModule.gallery,
    ExportModule.memories,
    ExportModule.wishJar,
  };

  static const _modules = [
    (
      ExportModule.chat,
      'Chat',
      'Every message, photo, voice note, video and file',
    ),
    (ExportModule.gallery, 'Gallery', "The shared gallery's original files"),
    (ExportModule.memories, 'Memories', 'Memory threads and their photographs'),
    (ExportModule.wishJar, 'Wish Jar', 'Your own entries only'),
    (ExportModule.vault, 'Private Vault', 'Asks for your vault PIN'),
    (ExportModule.profile, 'Profile', 'Your profile and when you two linked'),
  ];

  _Phase _phase = _Phase.setup;
  bool _vaultUnlocked = false;
  bool _cancelRequested = false;
  String _runningModule = '';
  String _runningItem = '';
  ExportSummary? _summary;
  String? _error;

  @override
  void dispose() {
    // The display may sleep again no matter how the screen was left — the
    // finally in _start covers the normal end, this covers a pop mid-run.
    unawaited(_setAwake(false));
    // Leaving the screen cancels — v1 runs in the foreground only, and a run
    // nobody is watching must not keep writing decrypted files. The item in
    // flight still finishes; DataExportService polls this between items.
    _cancelRequested = true;
    super.dispose();
  }

  /// The call screen's idiom (call_controller._setAwake): v1 is foreground-
  /// only, so the display going to sleep mid-run IS the run dying — the
  /// screen has to hold the phone awake for as long as it is writing.
  Future<void> _setAwake(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      debugPrint('[export] wakelock failed: $e');
    }
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _toggleModule(ExportModule module, bool on) async {
    if (module == ExportModule.vault && on && !_vaultUnlocked) {
      final ok = await _verifyVaultPin();
      if (!ok || !mounted) return;
      _vaultUnlocked = true;
    }
    setState(() => on ? _selected.add(module) : _selected.remove(module));
  }

  /// The vault's server-side PIN check, same verdicts and same words as the
  /// vault gate. The export never sees vault bytes before this says 'ok'.
  Future<bool> _verifyVaultPin() async {
    var errorSignal = 0;
    var busy = false;
    String? message;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Vault PIN', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 6),
                const Text('The vault only opens with its own PIN.',
                    style: TextStyle(color: MilesColors.taupe, fontSize: 13),),
                const SizedBox(height: 10),
                SizedBox(
                  height: 20,
                  child: message == null
                      ? null
                      : Text(message!,
                          style: const TextStyle(
                              color: MilesColors.blush, fontSize: 13,),),
                ),
                const SizedBox(height: 10),
                PinPad(
                  errorSignal: errorSignal,
                  enabled: !busy,
                  onComplete: (pin) async {
                    setSheet(() => busy = true);
                    try {
                      final verdict = await VaultRepository.verifyPin(pin);
                      if (!ctx.mounted) return;
                      switch (verdict) {
                        case 'ok':
                          Navigator.pop(ctx, true);
                        case 'locked':
                          setSheet(() {
                            message = 'Too many tries. Locked for 15 minutes.';
                            errorSignal++;
                          });
                        case 'no_pin':
                          setSheet(() {
                            message =
                                'No vault PIN is set — open the vault once first.';
                            errorSignal++;
                          });
                        default: // 'wrong'
                          setSheet(() {
                            message = 'Wrong PIN';
                            errorSignal++;
                          });
                      }
                    } catch (_) {
                      if (ctx.mounted) {
                        setSheet(() {
                          message = "Couldn't check the PIN";
                          errorSignal++;
                        });
                      }
                    } finally {
                      if (ctx.mounted) setSheet(() => busy = false);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return ok ?? false;
  }

  Future<void> _start() async {
    final session = ref.read(sessionProvider);

    // The app lock is asked BEFORE anything decrypts or the picker opens —
    // the same order the app itself unlocks in. The system sheet backgrounds
    // this app, so the in-progress flag keeps the disguise cover from
    // reading that as someone walking away (vault_gate_screen.dart does the
    // identical dance for the identical reason).
    if (await AppLock.isEnabled()) {
      MilesApp.authInProgress = true;
      final ok = await AppLock.authenticate();
      MilesApp.authInProgress = false;
      if (!ok || !mounted) return;
    }

    // The SAF picker is a system window over our own app, not the user
    // leaving it — without the guard the cover comes up and the vault gate
    // re-locks under the picker.
    MilesApp.systemOverlayActive = true;
    String? tree;
    try {
      tree = await DataExportService.pickFolder();
    } on MissingPluginException {
      // iOS has no 'miles/export' host. The whole protocol below is Android's
      // Storage Access Framework, implemented in MainActivity.kt, and its iOS
      // counterpart (UIDocumentPicker + security-scoped bookmarks) is not
      // written yet.
      //
      // This catch is SEPARATE because MissingPluginException does not extend
      // PlatformException — the clause below never saw it, so on iOS the
      // failure escaped uncaught and the button did nothing at all, with no
      // toast and no error. Telling the user plainly is the honest failure;
      // silence reads as a broken app.
      _toast('Export is not available on iOS yet.');
      return;
    } on PlatformException catch (e) {
      _toast(e.code == 'no_picker'
          ? 'This phone has no folder picker.'
          : "Couldn't open the folder picker.",);
      return;
    } finally {
      MilesApp.systemOverlayActive = false;
    }
    if (tree == null || !mounted) return; // backed out — nothing to do

    setState(() {
      _phase = _Phase.running;
      _error = null;
      _cancelRequested = false;
      _runningModule = '';
      _runningItem = '';
    });
    unawaited(_setAwake(true));
    try {
      final summary = await DataExportService.run(
        session: session,
        treeUri: tree,
        modules: _selected,
        onProgress: (module, item) {
          if (mounted) {
            setState(() {
              _runningModule = module;
              _runningItem = item;
            });
          }
        },
        cancelled: () => _cancelRequested,
      );
      if (mounted) {
        setState(() {
          _summary = summary;
          _phase = _Phase.done;
        });
      }
    } catch (e) {
      // run() only throws when the README cannot be written, which means the
      // folder itself refuses writes — nothing after it would have landed.
      if (mounted) {
        setState(() {
          _error = "Couldn't write to that folder — pick a different one. "
              '(${e.runtimeType})';
          _phase = _Phase.setup;
        });
      }
    } finally {
      unawaited(_setAwake(false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Export your data'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          // Backing out mid-run is allowed and cancels — dispose() says so.
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.setup => _buildSetup(session),
          _Phase.running => _buildRunning(),
          _Phase.done => _buildDone(),
        },
      ),
    );
  }

  Widget _buildSetup(SessionState session) {
    final linked = session.couple != null;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SurfacePanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_open, color: MilesColors.ember, size: 20),
                  SizedBox(width: 10),
                  Text('Read this first',
                      style: TextStyle(
                          color: MilesColors.cream50,
                          fontWeight: FontWeight.w600,),),
                ],
              ),
              SizedBox(height: 10),
              // This is the one screen whose whole job is telling somebody what
              // is and is not protected, so it is the last place that may round
              // the answer up — and it did, twice. "The app's own copies stay
              // encrypted" stopped being true on 2026-08-28 when the vault
              // moved to plaintext bytes in a private bucket
              // (vault_repository.saveMedia -> _uploadPlain); the shared
              // gallery never was (gallery_repository, "Deliberately NOT
              // encrypted"). Then the replacement said "your messages are
              // end-to-end encrypted", which over-claims in the other
              // direction: chat bodies seal on the device, but
              // ReleaseGate.chatCipherOnly defaults FALSE and falls back to
              // false on any failure to read the flag, so a plaintext body is
              // a supported outcome and the published policy lists chat under
              // "not end-to-end encrypted". Say what the policy says.
              Text(
                'This creates an unencrypted copy of everything you select, '
                'in a folder you choose. Anyone with that folder can read '
                "it. Your phone's gallery app and any cloud backup covering "
                'that folder can pick these files up. Inside the app, chat, '
                'gallery and vault items are kept in private storage that only '
                'you and your partner can open — but they are not end-to-end '
                'encrypted. Settings → Help & FAQ lists exactly what is.',
                style: TextStyle(color: MilesColors.taupe, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const _SectionHeader(label: 'What to include'),
        for (final (module, title, subtitle) in _modules)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: MilesColors.ember,
            value: _selected.contains(module),
            // A solo account has no chat, gallery, memories or jar to export;
            // a disabled row says so instead of failing later.
            onChanged: !linked && _needsCouple.contains(module)
                ? null
                : (v) => _toggleModule(module, v ?? false),
            title: Text(title,
                style: const TextStyle(color: MilesColors.cream50),),
            subtitle: Text(
              !linked && _needsCouple.contains(module)
                  ? 'Needs a linked partner'
                  : subtitle,
              style: const TextStyle(color: MilesColors.taupe, fontSize: 12),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_error!,
                style: const TextStyle(color: MilesColors.blush),),
          ),
        const SizedBox(height: 16),
        GlowButton(
          label: 'Choose a folder and export',
          color: MilesColors.blush,
          onPressed: _selected.isEmpty ? null : _start,
        ),
        const SizedBox(height: 12),
        const Text(
          'The export runs only while this screen is open. Leaving it stops '
          'the export after the current file. The screen is kept awake while '
          'it runs.',
          textAlign: TextAlign.center,
          style: TextStyle(color: MilesColors.taupe, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }

  Widget _buildRunning() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _runningModule.isEmpty ? 'Starting…' : _runningModule,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            _runningItem,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: MilesColors.taupe, fontSize: 13),
          ),
          const SizedBox(height: 24),
          const LinearProgressIndicator(color: MilesColors.ember),
          const SizedBox(height: 24),
          TextButton(
            onPressed: _cancelRequested
                ? null
                : () => setState(() => _cancelRequested = true),
            child: Text(
              _cancelRequested ? 'Stopping…' : 'Stop after this file',
              style: const TextStyle(color: MilesColors.gilt),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Keep this screen open — leaving it stops the export.',
            textAlign: TextAlign.center,
            style: TextStyle(color: MilesColors.taupe, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildDone() {
    final summary = _summary!;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (summary.cancelled) ...[
          const Text(
            'Export stopped early. Everything already written stays in the '
            'folder.',
            style: TextStyle(color: MilesColors.ember, height: 1.5),
          ),
          const SizedBox(height: 16),
        ],
        for (final m in summary.modules) ...[
          SurfacePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(m.label,
                          style: const TextStyle(
                              color: MilesColors.cream50,
                              fontWeight: FontWeight.w600,),),
                    ),
                    Text(
                      '${m.exported} exported',
                      style: const TextStyle(
                          color: MilesColors.taupe, fontSize: 12,),
                    ),
                  ],
                ),
                // Failure honesty: every item that did not make it is named
                // here, with its reason class — never buried in a total.
                for (final f in m.failures)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${f.item} — ${f.reason}',
                      style: const TextStyle(
                          color: MilesColors.ember, fontSize: 12,),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (summary.failed > 0) ...[
          const Text(
            'A file that failed part-way may remain in the folder, cut '
            'short.',
            style: TextStyle(
                color: MilesColors.taupe, fontSize: 12, height: 1.5,),
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: 8),
        GlowButton(
          label: 'Done',
          color: MilesColors.blush,
          onPressed: () => context.pop(),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 2,
          fontWeight: FontWeight.w600,
          color: MilesColors.gilt,
        ),
      ),
    );
  }
}
