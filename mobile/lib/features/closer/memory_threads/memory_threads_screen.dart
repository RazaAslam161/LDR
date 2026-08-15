import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/closer_load_result.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/media/media_decode_queue.dart';
import 'package:miles/features/closer/memory_threads/memory_failure.dart';
import 'package:miles/features/closer/memory_threads/memory_heal.dart';
import 'package:miles/features/closer/memory_threads/memory_photo_repository.dart';
import 'package:miles/features/closer/memory_threads/memory_pin_gate.dart';
import 'package:miles/features/closer/memory_threads/memory_thread_repository.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Memory Threads — PIN-gated timeline of intimate milestones.
///
/// Entry is gated by biometric or a 4-digit PIN (spec §F9: "sits behind its
/// OWN 6-digit PIN / biometric prompt, on top of the general Closer gate").
/// The gate is shown on every entry; there's no persistent "unlocked" session.
class MemoryThreadsScreen extends ConsumerStatefulWidget {
  const MemoryThreadsScreen({super.key});

  @override
  ConsumerState<MemoryThreadsScreen> createState() =>
      _MemoryThreadsScreenState();
}

class _MemoryThreadsScreenState extends ConsumerState<MemoryThreadsScreen> {
  /// null = gate not yet passed; true = unlocked; false = locked.
  bool? _unlocked;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: switch (_unlocked) {
            null =>
              _PinGate(onUnlocked: () => setState(() => _unlocked = true)),
            false =>
              _PinGate(onUnlocked: () => setState(() => _unlocked = true)),
            true => _UnlockedView(),
          },
        ),
      ),
    );
  }
}

// ─── PIN gate ──────────────────────────────────────────────────────────────

class _PinGate extends StatefulWidget {
  const _PinGate({required this.onUnlocked});
  final VoidCallback onUnlocked;

  @override
  State<_PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<_PinGate> {
  final _controller = TextEditingController();
  bool _checking = false;
  bool _needsSetup = false;
  bool _bioAttempted = false;
  String? _error;
  String _enteredPin = '';

  /// The first of the two entries while setting a PIN.
  String? _firstEntry;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Forget the PIN, after proving the account password.
  ///
  /// [MemoryPinGate.clearAppPin] existed with **zero call sites** and there was
  /// no "forgot" affordance anywhere, so the only escape from four forgotten
  /// digits was reinstalling the app — which regenerates this device's X25519
  /// key, changes the ECDH shared secret, and permanently orphans every
  /// encrypted row the couple has. And because `publishMyPublicKey` upserts
  /// over the old value, that happens on BOTH phones, not just this one.
  ///
  /// So the PIN gap and the key-loss gap compound into total data loss, and
  /// this is the cheap half of that pair.
  ///
  /// The password is REQUIRED, not merely offered: without it "forgot my PIN"
  /// is a button that removes the lock, which is not a lock.
  Future<void> _forgotPin() async {
    final password = await _askPassword();
    if (password == null || password.isEmpty || !mounted) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final email = SupabaseService.client.auth.currentUser?.email;
    if (email == null) {
      setState(() {
        _checking = false;
        _error = 'Sign in again to reset your PIN.';
      });
      return;
    }
    try {
      await SupabaseService.client.auth
          .signInWithPassword(email: email, password: password);
      await MemoryPinGate.clearAppPin();
      if (!mounted) return;
      setState(() {
        _checking = false;
        _needsSetup = true;
        _firstEntry = null;
        _enteredPin = '';
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = "That password didn't match.";
      });
    }
  }

  Future<String?> _askPassword() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B26),
        title: const Text(
          'Reset your PIN',
          style: TextStyle(color: Color(0xFFFBF8F4), fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter your account password. Your memories are not affected — '
              'this only replaces the four digits.',
              style: TextStyle(color: Color(0x99F5EFE6), height: 1.5, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(color: Color(0xFFFBF8F4)),
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // Prevent re-triggering biometric if we've already attempted it
    if (_bioAttempted) return;
    _bioAttempted = true;

    final hasPin = await MemoryPinGate.hasAppPin();
    if (!mounted) return;
    setState(() => _needsSetup = !hasPin);

    if (hasPin) {
      // Try biometric first; if it succeeds, unlock immediately.
      setState(() => _checking = true);
      final bio = await MemoryPinGate.authenticateBiometric();
      if (!mounted) return;
      if (bio) {
        widget.onUnlocked();
        return;
      }
      setState(() => _checking = false);
    }
  }

  Future<void> _submitPin() async {
    final pin = _enteredPin;
    if (pin.length != 4) {
      setState(() => _error = 'Enter 4 digits.');
      return;
    }

    setState(() {
      _checking = true;
      _error = null;
    });

    if (_needsSetup) {
      // Confirm-entry. You used to type four digits ONCE and that was your PIN
      // forever — a typo you could not have noticed, guarding data whose only
      // other key is on a device you may reinstall.
      if (_firstEntry == null) {
        setState(() {
          _firstEntry = pin;
          _enteredPin = '';
          _checking = false;
        });
        return;
      }
      if (_firstEntry != pin) {
        setState(() {
          _firstEntry = null;
          _enteredPin = '';
          _checking = false;
          _error = "Those didn't match. Start again.";
        });
        return;
      }
      await MemoryPinGate.setAppPin(pin);
      if (!mounted) return;
      widget.onUnlocked();
      return;
    }

    final ok = await MemoryPinGate.verifyAppPin(pin);
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
    } else {
      setState(() {
        _checking = false;
        _error = 'Wrong PIN. Try again.';
        _enteredPin = '';
      });
    }
  }

  void _onKey(String digit) {
    if (_enteredPin.length >= 4) return;
    setState(() {
      _enteredPin += digit;
      _error = null;
    });
    if (_enteredPin.length == 4) {
      _submitPin();
    }
  }

  void _onBackspace() {
    if (_enteredPin.isEmpty) return;
    setState(() {
      _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(
          title: 'Memory Threads',
          subtitle: 'PIN required',
          onBack: () => context.pop(),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🧵', style: TextStyle(fontSize: 40)),
                  const SizedBox(height: 12),
                  Text(
                    !_needsSetup
                        ? 'Enter your PIN'
                        : _firstEntry == null
                            ? 'Set a 4-digit PIN'
                            : 'Enter it again',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          color: const Color(0xFFFBF8F4),
                          fontSize: 20,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    !_needsSetup
                        ? 'Or use biometrics when available.'
                        : _firstEntry == null
                            ? "You'll enter this each time you open Memory "
                                'Threads.'
                            : 'Just to be sure it is what you meant.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0x66F5EFE6),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // PIN dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (i) {
                      final filled = i < _enteredPin.length;
                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: filled
                              ? const Color(0xFFEF6F58)
                              : Colors.transparent,
                          border: Border.all(
                            color: const Color(0x66F5EFE6),
                          ),
                        ),
                      );
                    }),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFEF6F58),
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (!_needsSetup) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _checking ? null : _forgotPin,
                      child: const Text(
                        'Forgot your PIN?',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0x99F5EFE6),
                        ),
                      ),
                    ),
                  ],
                  if (_checking) ...[
                    const SizedBox(height: 16),
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                  const SizedBox(height: 32),
                  _numpad,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget get _numpad {
    const keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'back'],
    ];
    return SizedBox(
      width: 240,
      child: Column(
        children: keys.map((row) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: row.map((k) {
                if (k.isEmpty) {
                  return const SizedBox(width: 60, height: 60);
                }
                if (k == 'back') {
                  return IconButton(
                    onPressed: _onBackspace,
                    icon: const Icon(
                      Icons.backspace_outlined,
                      color: Color(0xCCF5EFE6),
                    ),
                    iconSize: 22,
                  );
                }
                return GestureDetector(
                  onTap: () => _onKey(k),
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: MilesColors.surface2,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      k,
                      style: const TextStyle(
                        color: Color(0xFFFBF8F4),
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── Unlocked list view ────────────────────────────────────────────────────

class _UnlockedView extends ConsumerStatefulWidget {
  @override
  ConsumerState<_UnlockedView> createState() => _UnlockedViewState();
}

class _UnlockedViewState extends ConsumerState<_UnlockedView> {
  Stream<CloserLoadResult<MemoryThread>>? _threadsStream;
  String? _error;

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure();
    _ensureKeyAndLoad();
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    super.dispose();
  }

  Future<void> _ensureKeyAndLoad() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    if (couple == null || me == null) {
      if (!mounted) return;
      setState(() {
        _error = 'Link your partner to use Memory Threads.';
      });
      return;
    }

    try {
      await ensureSharedKey(session);
      if (!mounted) return;
      setState(() {
        _threadsStream = MemoryThreadRepository.streamThreads(couple.id);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = partnerKeyMessage(e);
      });
    }
  }

  Future<void> _propose() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    await context.push<bool>(
      '/app/closer/memory-threads/propose',
    );
    // Refresh the stream after proposing so the new thread appears immediately
    if (!mounted) return;
    _ensureKeyAndLoad();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Header(
          title: 'Memory Threads',
          subtitle: "Milestones you've kept.",
          onBack: () => context.pop(),
        ),
        Expanded(
          child: _error != null
              ? _ErrorState(message: _error!, onRetry: _ensureKeyAndLoad)
              : _threadsStream == null
                  ? const Center(child: CircularProgressIndicator())
                  : StreamBuilder<CloserLoadResult<MemoryThread>>(
                      stream: _threadsStream,
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          // Never snapshot.error.toString(). A dropped socket
                          // used to paint a PostgrestException, its SQLSTATE
                          // and its hint across the screen.
                          return _ErrorState(
                            message: "Couldn't load your memories. Pull to try "
                                'again.',
                            onRetry: _ensureKeyAndLoad,
                          );
                        }
                        if (!snapshot.hasData) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        final result = snapshot.data!;
                        _healWhenSettled(result.items);
                        if (result.items.isEmpty) {
                          // An empty list and a list where every row failed to
                          // decrypt used to render identically — which is the
                          // exact failure closer_load_result.dart was written
                          // to prevent, and its unreadableMessage had zero call
                          // sites in this feature. To the person looking at it,
                          // "empty" reads as "my data is gone".
                          return result.hasUnreadable
                              ? _UnreadableState(message: result.unreadableMessage)
                              : _emptyState();
                        }
                        return ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: result.items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, i) {
                            final me = ref.read(sessionProvider).profile!.id;
                            return _MemoryCard(
                              thread: result.items[i],
                              isMine: result.items[i].proposer == me,
                            );
                          },
                        );
                      },
                    ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: FilledButton.icon(
            onPressed: _threadsStream == null ? null : _propose,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Propose a memory'),
          ),
        ),
      ],
    );
  }

  /// Kicks heal-on-read once the list has been still.
  ///
  /// Called from `build`, which is why it must be cheap and idempotent: the
  /// debounce lives in [MemoryHeal] so a rebuild storm collapses to one attempt
  /// rather than one per frame.
  void _healWhenSettled(List<MemoryThread> threads) {
    final session = ref.read(sessionProvider);
    final coupleId = session.couple?.id;
    final me = session.profile?.id;
    if (coupleId == null || me == null) return;
    MemoryHeal.onListSettled(threads: threads, coupleId: coupleId, me: me);
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🧵', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            Text(
              'Memory Threads',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: const Color(0xFFFBF8F4),
                  ),
            ),
            const SizedBox(height: 12),
            const Text(
              'A PIN-kept timeline of the moments that mattered. '
              'Propose one — your partner adds it to the thread.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0x99F5EFE6), height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// One memory entry in the timeline. Decrypts title + note lazily on build.
class _MemoryCard extends StatefulWidget {
  const _MemoryCard({
    required this.thread,
    required this.isMine,
  });
  final MemoryThread thread;
  final bool isMine;

  @override
  State<_MemoryCard> createState() => _MemoryCardState();
}

class _MemoryCardState extends State<_MemoryCard> {
  String? _title;
  String? _note;
  MemoryFailure? _failure;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _decrypt();
  }

  @override
  void didUpdateWidget(covariant _MemoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.thread.id != widget.thread.id ||
        oldWidget.thread.state != widget.thread.state) {
      _decrypt();
    }
  }

  Future<void> _decrypt() async {
    try {
      final results = await Future.wait([
        decryptTitle(widget.thread),
        if (widget.thread.noteCipher != null) decryptNote(widget.thread),
      ]);
      if (!mounted) return;
      setState(() {
        var i = 0;
        _title = results[i++];
        if (widget.thread.noteCipher != null) {
          _note = results[i];
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // The classification lives here, at the decrypt, and not on the
        // repository's parse: `title_cipher` is opened long after `fromJson`
        // has already declared the row readable, so a MAC failure — the only
        // permanent one — was reported by nothing at all.
        _failure = MemoryFailure.ofRow(e);
        _loading = false;
      });
    }
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      // One tap, no note. Who is accepting is auth.uid() inside the RPC, not a
      // parameter — passing it was how a proposer could accept their own.
      await MemoryThreadRepository.accept(widget.thread.id);
    } catch (e) {
      _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Take back your own pending proposal. The state all nine production rows
  /// are stuck in previously had no action at all for the person who made it.
  Future<void> _withdraw() async {
    final confirmed = await _confirm(
      "Take this back? Your partner won't see it any more.",
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.withdraw(widget.thread.id);
    } catch (e) {
      _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _archive() async {
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.archive(widget.thread.id);
    } catch (e) {
      _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Unarchive had no busy guard and no error handling at all — a bare inline
  /// `await` in the chip's callback, so a failure vanished and a double tap
  /// fired twice.
  Future<void> _unarchive() async {
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.unarchive(widget.thread.id);
    } catch (e) {
      _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What to say when a lifecycle call fails.
  ///
  /// Never the exception. `'Failed: $e'` on a PostgrestException prints the
  /// RPC's raised message, the SQLSTATE and the hint at the user; on a MAC
  /// failure it printed "SecretBoxAuthenticationError: SecretBox has wrong
  /// message authentication code (MAC)". The RPCs raise exactly three
  /// conditions a person can act on, so those three get sentences and
  /// everything else gets the honest generic.
  String _friendly(Object e) {
    final raw = e is PostgrestException ? e.message : e.toString();
    if (raw.contains('only your partner can confirm')) {
      return "You asked for this one — she has to confirm it.";
    }
    if (raw.contains('not yours to accept')) {
      return 'Only your partner can accept this.';
    }
    if (raw.contains('not yours to withdraw')) {
      return 'Only the person who proposed this can take it back.';
    }
    if (raw.contains('not yet')) {
      return 'Not yet — you can delete this yourself 14 days after asking.';
    }
    return "That didn't go through. Try again.";
  }

  Future<void> _requestDelete() async {
    final confirmed = await _confirm(
      'Request deletion? Your partner will need to confirm.',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.requestDeletion(widget.thread.id);
    } catch (e) {
      _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete() async {
    // The old copy said "This cannot be undone" over a call that only flipped a
    // column, leaving the ciphertext in the row indefinitely. It now says what
    // actually happens: the row and its objects are erased by the nightly purge
    // and reap within 30 days.
    final confirmed = await _confirm(
      "Delete this for both of you? The encrypted files are erased within "
      '30 days.',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.confirmDeletion(widget.thread.id);
    } catch (e) {
      _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelDelete() async {
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.cancelDeletion(widget.thread.id);
    } catch (e) {
      _toast(_friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPhoto() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _MemoryPhotoView(thread: widget.thread),
        fullscreenDialog: true,
      ),
    );
  }

  String? _readMe() {
    final ctx = context;
    // We're inside a ConsumerState's build tree — find the nearest reader.
    // (Simpler than threading a ref down: this card is always within the
    // MemoryThreadsScreen ConsumerState subtree.)
    final container = ProviderScope.containerOf(ctx, listen: false);
    final session = container.read(sessionProvider);
    return session.profile?.id;
  }

  Future<bool> _confirm(String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B26),
        content: Text(
          message,
          style: const TextStyle(color: Color(0xFFFBF8F4), height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1F2937),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.thread.happenedOn.toLocal();
    final dateStr =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _borderColor,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🧵', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Text(
                dateStr,
                style: const TextStyle(
                  color: Color(0xFFF4937E),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _stateBadge,
            ],
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_failure != null) ...[
            // Muted, not red, and the date and badge above it stay: the entry
            // is still on the thread. The likeliest cause is her key not being
            // published yet, where nothing is wrong and nothing is lost, and
            // alarm colour would be a lie about it.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: MilesColors.surface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _failure!.message,
                style: const TextStyle(
                  color: Color(0x99F5EFE6),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 14),
            // The lifecycle chips read `state` and `proposer`, which are
            // plaintext and need no key. Dropping them with the body left a
            // permanently-locked memory with no way to archive or delete it —
            // a row you can neither read nor be rid of.
            _actions(),
          ] else ...[
            Text(
              _title ?? '',
              style: const TextStyle(
                color: Color(0xFFFBF8F4),
                fontSize: 16,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            if (_note != null && _note!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _note!,
                style: const TextStyle(
                  color: Color(0xCCF5EFE6),
                  height: 1.5,
                  fontSize: 13,
                ),
              ),
            ],
            if (widget.thread.coverPath != null) ...[
              const SizedBox(height: 12),
              _MemoryCover(thread: widget.thread, onTap: _openPhoto),
            ] else if (widget.thread.photoNonce != null) ...[
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _openPhoto,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: MilesColors.tint(const Color(0xFFEF6F58), 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.image_outlined,
                        size: 14,
                        color: Color(0xFFEF6F58),
                      ),
                      SizedBox(width: 4),
                      Text(
                        'View photo',
                        style: TextStyle(
                          color: Color(0xFFEF6F58),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            _actions(),
          ],
        ],
      ),
    );
  }

  Color get _borderColor {
    switch (widget.thread.state) {
      case MemoryState.proposed:
        return const Color(0xFFF4937E).withValues(alpha: 0.3);
      case MemoryState.archived:
        return const Color(0x1aF5EFE6);
      case MemoryState.deletionRequested:
        return const Color(0xFFEF6F58).withValues(alpha: 0.5);
      default:
        return const Color(0xFFEF6F58).withValues(alpha: 0.18);
    }
  }

  Widget get _stateBadge {
    final s = widget.thread.state;
    String label;
    Color color;
    switch (s) {
      case MemoryState.proposed:
        label = 'Pending';
        color = const Color(0xFFF4937E);
      case MemoryState.accepted:
        label = 'Live';
        color = const Color(0xFF34D399);
      case MemoryState.archived:
        label = 'Archived';
        color = const Color(0x80F5EFE6);
      case MemoryState.deletionRequested:
        label = 'Delete pending';
        color = const Color(0xFFEF6F58);
      case MemoryState.deleted:
        label = 'Deleted';
        color = const Color(0x66F5EFE6);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: MilesColors.tint(color, 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _actions() {
    final me = _readMe();
    final state = widget.thread.state;
    final iRequested = widget.thread.deleteRequestedBy == me;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (state == MemoryState.proposed && !widget.isMine)
          _actionChip('Accept', Icons.check, _accept),
        // The proposer's own pending memory used to render an EMPTY row: the
        // only 'proposed' branch required !isMine. Nine of nine production rows
        // are in this state, so the person who created them had no move at all.
        if (state == MemoryState.proposed && widget.isMine)
          _actionChip('Take it back', Icons.undo, _withdraw),
        if (state == MemoryState.accepted)
          _actionChip('Archive', Icons.archive_outlined, _archive),
        if (state == MemoryState.archived)
          _actionChip('Unarchive', Icons.unarchive_outlined, _unarchive),
        // Archived was previously a dead end — Request delete was gated on
        // 'accepted' alone, so archiving quietly removed the only way to
        // delete, and nothing said so.
        if (state == MemoryState.accepted || state == MemoryState.archived)
          _actionChip('Request delete', Icons.delete_outline, _requestDelete),
        // EITHER partner may cancel. The repository always said so ("either can
        // veto by cancelling"); the UI showed it to the requester alone.
        if (state == MemoryState.deletionRequested)
          _actionChip('Keep it', Icons.close, _cancelDelete),
        if (state == MemoryState.deletionRequested && !iRequested)
          _actionChip('Delete it', Icons.delete_forever, _confirmDelete),
      ],
    );
  }

  Widget _actionChip(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: MilesColors.surface2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: const Color(0xCCF5EFE6)),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xCCF5EFE6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Every row loaded, none of them readable.
///
/// Distinct from the empty state on purpose. `closer_load_result.dart` counts
/// unreadable rows and its message had **zero call sites** in this feature, so
/// the repository knew and the screen never asked — and the screen it drew
/// instead said "nothing here yet" to someone whose memories all exist.
class _UnreadableState extends StatelessWidget {
  const _UnreadableState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔒', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xCCF5EFE6),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "They're still here. Nothing has been deleted.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0x80F5EFE6)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The memory's cover, painted from its own 1024px encrypted object.
///
/// What this replaces is a 12px text pill reading "View photo" — the photograph
/// being the only thing a memory is actually about. What it replaces
/// MECHANICALLY matters more: the old path pulled the full-size inline
/// ciphertext out of the row and decoded it at source resolution, so a
/// 12-megapixel photograph cost ~48 MB of raster to show a thumbnail.
class _MemoryCover extends StatefulWidget {
  const _MemoryCover({required this.thread, required this.onTap});

  final MemoryThread thread;
  final VoidCallback onTap;

  @override
  State<_MemoryCover> createState() => _MemoryCoverState();
}

class _MemoryCoverState extends State<_MemoryCover> {
  ImageProvider? _provider;
  MemoryFailure? _failure;

  /// Why there is legitimately nothing to show. Distinct from [_failure],
  /// which means we tried and could not.
  String? _blank;
  bool _mounted = true;

  /// 16:10, and the height is reserved from a constant BEFORE the bytes arrive.
  /// A frame that grows when the picture lands is a reflow of everything below
  /// it, which is the difference between a list that settles and one that jumps.
  static const double _aspect = 16 / 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _mounted = false;
    super.dispose();
  }

  Future<void> _load() async {
    final path = widget.thread.coverPath;
    if (path == null) {
      if (_mounted) setState(() => _blank = 'No photo on this memory yet.');
      return;
    }
    // cover_photo_id went unwritten by the sync trigger for a while, and the
    // decrypt cannot build its associated data without it. The path is
    // `$coupleId/memory/$photoId/c.enc`, so the id is recoverable from it — a
    // missing id must not mean a permanently blank cover.
    final segments = path.split('/');
    final photoId = widget.thread.coverPhotoId ??
        (segments.length > 2 ? segments[2] : null);
    if (photoId == null) {
      if (_mounted) setState(() => _blank = "This memory's photo is missing.");
      return;
    }

    // Computed from the SCREEN, not from this card, and therefore identical for
    // every card on it. A width derived per-card gives each one its own
    // ImageCache entry and its own decode of the same size.
    final media = MediaQuery.of(context);
    final width =
        ((media.size.width - 48) * media.devicePixelRatio).round();

    // Keyed on the storage object, not the thread: two items in one memory
    // share a thread id, so a per-thread key would make them dedupe each other
    // into silence the moment a memory holds more than one photo.
    final done = await MediaDecodeQueue.run<bool>(
      path,
      () => _mounted,
      () async {
        try {
          final p = await EncryptedMediaCache.coverProvider(
            path: path,
            associatedData:
                MemoryPhotoRepository.coverAdFor(widget.thread.id, photoId),
            decodeWidth: width,
          );
          if (_mounted) setState(() => _provider = p);
          return true;
        } catch (e) {
          // A cover is a downloaded object, so a MAC failure on it is a
          // truncated file as often as a lost key — `ofObject` refuses to call
          // that permanent. The branch this replaces called EVERY non-media
          // failure "locked to an older install", including the missing-key
          // StateError that heals itself.
          if (_mounted) setState(() => _failure = MemoryFailure.ofObject(e));
          return true;
        }
      },
    );

    // Null means the work was dropped, not that there was nothing to load. The
    // widget tree is torn down on every glance at the notification shade, so
    // this is ordinary — and treating it as a finished load is what left a
    // permanently empty box behind.
    if (done == null && _mounted && _provider == null && _failure == null) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AspectRatio(
          aspectRatio: _aspect,
          child: DecoratedBox(
            // A miss paints the surface, never a spinner: at 400ms most of
            // these resolve from disk faster than an indicator is allowed to
            // appear, and a wheel per card is what the old screen looked like.
            decoration: const BoxDecoration(color: MilesColors.surface2),
            child: _failure != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _failure!.message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0x99F5EFE6),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  )
                : _blank != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _blank!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0x99F5EFE6),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      )
                    : _provider == null
                        // Still working. An unexplained empty box was the
                        // resting state for every silent path through _load,
                        // and it is what the user photographed.
                        ? const Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                    : Image(
                        image: _provider!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        // In 150ms, out ZERO. The 1000ms default fade-out
                        // composites two frames per recycled cell for a full
                        // second while scrolling.
                        frameBuilder: (_, child, frame, wasSync) =>
                            wasSync || frame != null
                                ? AnimatedOpacity(
                                    opacity: 1,
                                    duration: const Duration(milliseconds: 150),
                                    child: child,
                                  )
                                : const SizedBox.expand(),
                        // A decode failure surfaces on the ImageStream, not in
                        // _load's try, so without this the codec giving up is
                        // one more silent empty box.
                        errorBuilder: (_, __, ___) => const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              "This photo couldn't be displayed.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Color(0x99F5EFE6),
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
          ),
        ),
      ),
    );
  }
}

class _MemoryPhotoView extends StatefulWidget {
  const _MemoryPhotoView({required this.thread});
  final MemoryThread thread;

  @override
  State<_MemoryPhotoView> createState() => _MemoryPhotoViewState();
}

class _MemoryPhotoViewState extends State<_MemoryPhotoView> {
  Uint8List? _bytes;
  MemoryFailure? _failure;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure();
    _load();
  }

  Future<void> _load() async {
    // Which side of the classification the catch belongs on: the inline column
    // comes from Postgres over TLS, the object from the CDN through a disk
    // cache, and only the first can honestly produce KeyGoneForever.
    var fromObject = false;
    try {
      // Once MemoryHeal has moved a photo out to storage it nulls the inline
      // photo_cipher/photo_nonce columns, and decryptPhoto returns null without
      // throwing — which rendered neither image, spinner nor error, just black.
      // A healed memory must be read from the object it was moved to.
      if (widget.thread.coverPath != null) {
        final photos = await MemoryPhotoRepository.listFor(widget.thread.id);
        if (photos.isNotEmpty) {
          final photo = photos.first;
          fromObject = true;
          final bytes = await EncryptedMediaCache.bytes(
            bucket: privateBucket,
            path: photo.fullPath,
            associatedData:
                MemoryPhotoRepository.fullAdFor(widget.thread.id, photo.id),
          );
          if (!mounted) return;
          setState(() {
            _bytes = bytes;
            _loading = false;
          });
          return;
        }
      }

      final bytes = await decryptPhoto(widget.thread);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        // Never leave all three null: that combination is a black screen with
        // nothing to tell the user, or a future regression, why. Both columns
        // null IS the missing-file case, and it already has a sentence.
        _failure =
            bytes == null ? const MemoryMediaFailure(MediaMissing()) : null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = fromObject
            ? MemoryFailure.ofObject(e)
            : MemoryFailure.ofRow(e);
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (_loading)
              const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_failure != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    _failure!.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xCCF5EFE6),
                      height: 1.5,
                    ),
                  ),
                ),
              )
            else if (_bytes != null)
              InteractiveViewer(
                child: Center(child: Image.memory(_bytes!)),
              ),
            Positioned(
              top: 8,
              left: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Color(0xCCFBF8F4)),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shared widgets ────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onBack,
  });
  final String title;
  final String subtitle;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0x80F5EFE6)),
            onPressed: onBack,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0x66F5EFE6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lock_outline,
              color: Color(0xFFEF6F58),
              size: 36,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xCCF5EFE6), height: 1.5),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
