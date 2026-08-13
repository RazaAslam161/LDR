import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/closer_load_result.dart';
import 'package:miles/features/closer/memory_threads/memory_pin_gate.dart';
import 'package:miles/features/closer/memory_threads/memory_thread_repository.dart';
import 'package:miles/features/closer/secure_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _bootstrap();
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
                    _needsSetup ? 'Set a 4-digit PIN' : 'Enter your PIN',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          color: const Color(0xFFFBF8F4),
                          fontSize: 20,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _needsSetup
                        ? "You'll enter this each time you open Memory Threads."
                        : 'Or use biometrics when available.',
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
        _error = e.toString().replaceFirst('Exception: ', '');
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
                          return _ErrorState(
                            message: snapshot.error.toString(),
                            onRetry: _ensureKeyAndLoad,
                          );
                        }
                        if (!snapshot.hasData) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        final result = snapshot.data!;
                        if (result.items.isEmpty) {
                          return _emptyState();
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
  String? _error;
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
        _error = 'Could not decrypt: $e';
        _loading = false;
      });
    }
  }

  Future<void> _accept() async {
    final me = _readMe();
    if (me == null) return;
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.accept(
        threadId: widget.thread.id,
        acceptedBy: me,
      );
    } catch (e) {
      _toast('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _archive() async {
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.archive(widget.thread.id);
    } catch (e) {
      _toast('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestDelete() async {
    final me = _readMe();
    if (me == null) return;
    final confirmed = await _confirm(
      'Request deletion? Your partner will need to confirm.',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.requestDeletion(
        threadId: widget.thread.id,
        requestedBy: me,
      );
    } catch (e) {
      _toast('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDelete() async {
    final me = _readMe();
    if (me == null) return;
    final confirmed = await _confirm(
      'Permanently delete this memory? This cannot be undone.',
    );
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.hardDelete(
        threadId: widget.thread.id,
        deletedBy: me,
      );
    } catch (e) {
      _toast('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelDelete() async {
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.cancelDeletion(widget.thread.id);
    } catch (e) {
      _toast('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revisit() async {
    final me = _readMe();
    if (me == null) return;
    setState(() => _busy = true);
    try {
      await MemoryThreadRepository.requestRevisit(
        threadId: widget.thread.id,
        initiatedBy: me,
      );
      _toast('Asked your partner to revisit.');
    } catch (e) {
      _toast('Failed: $e');
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
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFEF6F58), fontSize: 12),
              ),
            )
          else ...[
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
            if (widget.thread.photoCipher != null) ...[
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (widget.thread.state == MemoryState.proposed && !widget.isMine)
          _actionChip('Accept', Icons.check, _accept),
        if (widget.thread.state == MemoryState.accepted)
          _actionChip('Revisit together', Icons.favorite_outline, _revisit),
        if (widget.thread.state == MemoryState.accepted)
          _actionChip('Archive', Icons.archive_outlined, _archive),
        if (widget.thread.state == MemoryState.archived)
          _actionChip('Unarchive', Icons.unarchive_outlined, () async {
            await MemoryThreadRepository.unarchive(widget.thread.id);
          }),
        if (widget.thread.state == MemoryState.accepted)
          _actionChip(
            'Request delete',
            Icons.delete_outline,
            _requestDelete,
          ),
        if (widget.thread.state == MemoryState.deletionRequested &&
            widget.thread.deleteRequestedBy == me)
          _actionChip('Cancel delete', Icons.close, _cancelDelete),
        if (widget.thread.state == MemoryState.deletionRequested &&
            widget.thread.deleteRequestedBy != me)
          _actionChip('Confirm delete', Icons.delete_forever, _confirmDelete),
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

class _MemoryPhotoView extends StatefulWidget {
  const _MemoryPhotoView({required this.thread});
  final MemoryThread thread;

  @override
  State<_MemoryPhotoView> createState() => _MemoryPhotoViewState();
}

class _MemoryPhotoViewState extends State<_MemoryPhotoView> {
  Uint8List? _bytes;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await decryptPhoto(widget.thread);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not decrypt: $e';
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
            else if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xCCF5EFE6)),
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
