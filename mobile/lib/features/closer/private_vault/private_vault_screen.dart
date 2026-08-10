import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/private_vault/private_vault_repository.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:miles/main.dart' show MilesApp;

/// Private Vault — E2EE photo/note storage with user-controlled retention.
///
/// The list view shows a card per item: a decrypted preview (note text or a
/// blurred photo thumbnail), a retention badge, and the delete button. Tapping
/// a photo opens a full-screen decrypted view that sets FLAG_SECURE.
class PrivateVaultScreen extends ConsumerStatefulWidget {
  const PrivateVaultScreen({super.key});

  @override
  ConsumerState<PrivateVaultScreen> createState() => _PrivateVaultScreenState();
}

enum _LoadState { loading, ready, error }

class _PrivateVaultScreenState extends ConsumerState<PrivateVaultScreen> {
  _LoadState _state = _LoadState.loading;
  String? _error;
  List<VaultItem> _items = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureKeyAndLoad();
  }

  Future<void> _ensureKeyAndLoad() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    if (couple == null || me == null) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.error;
        _error = 'Link your partner to open the Vault.';
      });
      return;
    }

    setState(() => _state = _LoadState.loading);
    try {
      await ensureSharedKey(session);
      await _refresh(couple.id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.error;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _refresh(String coupleId) async {
    try {
      final result = await PrivateVaultRepository.fetchItems(coupleId);
      if (!mounted) return;
      if (result.hasUnreadable) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.unreadableMessage)),
        );
      }
      setState(() {
        _items = result.items;
        _state = _LoadState.ready;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _LoadState.error;
        _error = e.toString();
      });
    }
  }

  Future<void> _addNote() async {
    final couple = ref.read(sessionProvider).couple;
    final me = ref.read(sessionProvider).profile;
    if (couple == null || me == null) return;

    final text = await _showNoteDialog();
    if (text == null || text.trim().isEmpty) return;

    final ephemeral = await _confirmRetention() ?? false;
    try {
      await PrivateVaultRepository.insert(
        coupleId: couple.id,
        createdBy: me.id,
        kind: VaultKind.note,
        plaintextBytes: Uint8List.fromList(utf8.encode(text.trim())),
        retention: ephemeral ? VaultRetention.ephemeral : VaultRetention.keep,
      );
      await _refresh(couple.id);
    } catch (e) {
      _toast('Could not save: $e');
    }
  }

  Future<void> _addPhoto() async {
    final couple = ref.read(sessionProvider).couple;
    final me = ref.read(sessionProvider).profile;
    if (couple == null || me == null) return;

    final picker = ImagePicker();
    XFile? xfile;
    MilesApp.systemOverlayActive = true;
    try {
      xfile = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
    } finally {
      MilesApp.systemOverlayActive = false;
    }
    if (xfile == null) return;

    final bytes = await xfile.readAsBytes();

    final ephemeral = await _confirmRetention() ?? true;

    try {
      await PrivateVaultRepository.insert(
        coupleId: couple.id,
        createdBy: me.id,
        kind: VaultKind.photo,
        plaintextBytes: bytes,
        retention: ephemeral ? VaultRetention.ephemeral : VaultRetention.keep,
      );
      await _refresh(couple.id);
    } catch (e) {
      _toast('Could not save photo: $e');
    }
  }

  Future<String?> _showNoteDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B26),
        title: const Text(
          'New note',
          style: TextStyle(color: Color(0xFFFBF8F4), fontSize: 18),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          style: const TextStyle(color: Color(0xFFFBF8F4)),
          decoration: const InputDecoration(
            hintText: 'Something for the two of you…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Returns true for "Ephemeral", false for "Keep", null if dismissed.
  Future<bool?> _confirmRetention() async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B26),
        title: const Text(
          'How long should it stay?',
          style: TextStyle(color: Color(0xFFFBF8F4), fontSize: 18),
        ),
        content: const Text(
          'Keep — stays until both of you delete it.\n\n'
          'Ephemeral — auto-expires in 90 days unless both of you re-confirm.',
          style: TextStyle(color: Color(0xCCF5EFE6), height: 1.5),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ephemeral'),
          ),
        ],
      ),
    );
  }

  Future<void> _onDelete(VaultItem item) async {
    final me = ref.read(sessionProvider).profile!;
    switch (item.deleteState) {
      case VaultDeleteState.none:
        // Start the delete request.
        final confirmed = await _confirm(
          'Ask your partner to confirm the delete? You can force it in 14 days.',
        );
        if (!confirmed) return;
        await _guard(() => PrivateVaultRepository.requestDelete(
              itemId: item.id,
              requestedBy: me.id,
            ),);
        await _refresh(ref.read(sessionProvider).couple!.id);
      case VaultDeleteState.requested:
        if (item.deleteRequestedBy == me.id) {
          // Requester cancels.
          final confirmed = await _confirm('Cancel this delete request?');
          if (!confirmed) return;
          await _guard(() =>
              PrivateVaultRepository.cancelDeleteRequest(item.id),);
        } else {
          // Partner confirms → hard delete.
          final confirmed = await _confirm(
            'Confirm permanent delete? This cannot be undone.',
          );
          if (!confirmed) return;
          await _guard(() => PrivateVaultRepository.hardDelete(
                itemId: item.id,
                deletedBy: me.id,
              ),);
        }
        await _refresh(ref.read(sessionProvider).couple!.id);
      case VaultDeleteState.expired:
        if (item.deleteRequestedBy == me.id) {
          final confirmed = await _confirm(
            '14 days passed with no confirmation. Force delete now?',
          );
          if (!confirmed) return;
          await _guard(() => PrivateVaultRepository.hardDelete(
                itemId: item.id,
                deletedBy: me.id,
              ),);
          await _refresh(ref.read(sessionProvider).couple!.id);
        }
    }
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

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _toast('Failed: $e');
    }
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
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              title: 'Private Vault',
              subtitle: 'Yours alone. Encrypted on your phone.',
              onBack: () => context.pop(),
            ),
            Expanded(child: _body),
            _ActionBar(
              onAddNote: _addNote,
              onAddPhoto: _addPhoto,
            ),
          ],
        ),
      ),
    );
  }

  Widget get _body {
    switch (_state) {
      case _LoadState.loading:
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _LoadState.error:
        return _ErrorState(
          message: _error ?? 'Something went wrong.',
          onRetry: _ensureKeyAndLoad,
        );
      case _LoadState.ready:
        if (_items.isEmpty) {
          return const _EmptyVault();
        }
        return RefreshIndicator(
          onRefresh: () =>
              _refresh(ref.read(sessionProvider).couple!.id),
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: _items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final me = ref.read(sessionProvider).profile!.id;
              return _VaultItemCard(
                item: _items[i],
                isMine: _items[i].createdBy == me,
                onTap: () => _openItem(_items[i]),
                onDelete: () => _onDelete(_items[i]),
              );
            },
          ),
        );
    }
  }

  Future<void> _openItem(VaultItem item) async {
    if (item.kind == VaultKind.photo) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _SecurePhotoView(item: item),
          fullscreenDialog: true,
        ),
      );
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _NoteDetailView(item: item),
          fullscreenDialog: true,
        ),
      );
    }
  }
}

/// Common header used across Closer feature screens.
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

class _EmptyVault extends StatelessWidget {
  const _EmptyVault();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🔒', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 16),
            Text(
              'Your Private Vault',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: const Color(0xFFFBF8F4),
                  ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Yours alone. Encrypted on your phone — not even we can read it.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0x99F5EFE6),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add a note or photo below to begin.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0x66F5EFE6)),
            ),
          ],
        ),
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
            const Icon(Icons.lock_outline,
                color: Color(0xFFEF6F58), size: 36,),
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

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.onAddNote, required this.onAddPhoto});
  final VoidCallback onAddNote;
  final VoidCallback onAddPhoto;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onAddNote,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Note'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: onAddPhoto,
              icon: const Icon(Icons.photo_outlined, size: 18),
              label: const Text('Photo'),
            ),
          ),
        ],
      ),
    );
  }
}

class _VaultItemCard extends StatelessWidget {
  const _VaultItemCard({
    required this.item,
    required this.isMine,
    required this.onTap,
    required this.onDelete,
  });
  final VaultItem item;
  final bool isMine;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF141B26).withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: item.deleteState != VaultDeleteState.none
                  ? const Color(0xFFEF6F58).withValues(alpha: 0.4)
                  : const Color(0x1aF5EFE6),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _thumbnail,
              const SizedBox(width: 14),
              Expanded(child: _body),
              _deleteButton,
            ],
          ),
        ),
      ),
    );
  }

  Widget get _thumbnail {
    if (item.kind == VaultKind.photo) {
      return Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF1F2937),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.photo, color: Color(0xFFEF6F58), size: 24),
      );
    }
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.lock_outline, color: Color(0xFFF4937E), size: 24),
    );
  }

  Widget get _body {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              item.kind == VaultKind.photo ? 'Photo' : 'Note',
              style: const TextStyle(
                color: Color(0xFFFBF8F4),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            _retentionBadge,
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _metaLine,
          style: const TextStyle(fontSize: 11, color: Color(0x80F5EFE6)),
        ),
        if (item.deleteState != VaultDeleteState.none) ...[
          const SizedBox(height: 8),
          Text(
            item.deleteState == VaultDeleteState.expired
                ? (isMine
                    ? 'Delete window expired — you can force delete.'
                    : 'Delete window expired.')
                : (isMine
                    ? 'Waiting for your partner to confirm (14 days).'
                    : 'Your partner asked to delete this. Confirm?'),
            style: const TextStyle(fontSize: 11, color: Color(0xFFEF6F58)),
          ),
        ] else if (item.retention == VaultRetention.ephemeral &&
            item.reconfirmDue != null) ...[
          const SizedBox(height: 6),
          Text(
            _daysUntilReconfirm,
            style: const TextStyle(fontSize: 11, color: Color(0xFFF4937E)),
          ),
        ],
      ],
    );
  }

  String get _metaLine {
    final d = item.createdAt.toLocal();
    final dateStr =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return '${isMine ? 'You' : 'Partner'} · $dateStr';
  }

  String get _daysUntilReconfirm {
    final left = item.reconfirmDue!.difference(DateTime.now().toUtc());
    final days = left.inDays;
    if (days <= 0) {
      return 'Reconfirm soon or this will expire.';
    }
    return '$days day${days == 1 ? '' : 's'} until reconfirm.';
  }

  Widget get _retentionBadge {
    final ephemeral = item.retention == VaultRetention.ephemeral;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: ephemeral
            ? const Color(0xFFF4937E).withValues(alpha: 0.15)
            : const Color(0x14F5EFE6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        ephemeral ? 'Ephemeral' : 'Keep',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: ephemeral ? const Color(0xFFF4937E) : const Color(0x99F5EFE6),
        ),
      ),
    );
  }

  Widget get _deleteButton {
    final canAct = item.deleteState == VaultDeleteState.none ||
        item.deleteState == VaultDeleteState.expired && isMine ||
        item.deleteState == VaultDeleteState.requested;
    return IconButton(
      icon: Icon(
        item.deleteState == VaultDeleteState.none
            ? Icons.delete_outline
            : Icons.more_horiz,
        color: const Color(0xFFEF6F58),
        size: 20,
      ),
      onPressed: canAct ? onDelete : null,
    );
  }
}

/// Full-screen decrypted photo viewer. Sets FLAG_SECURE on entry so the surface
/// can't be screenshotted or recorded (spec §5.4 + §F4). FLAG_SECURE is cleared
/// on exit so it doesn't leak to other screens.
class _SecurePhotoView extends StatefulWidget {
  const _SecurePhotoView({required this.item});
  final VaultItem item;

  @override
  State<_SecurePhotoView> createState() => _SecurePhotoViewState();
}

class _SecurePhotoViewState extends State<_SecurePhotoView> {
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
      final bytes = await decryptVaultBytes(widget.item);
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
                child: Center(
                  child: Image.memory(_bytes!),
                ),
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

class _NoteDetailView extends StatefulWidget {
  const _NoteDetailView({required this.item});
  final VaultItem item;

  @override
  State<_NoteDetailView> createState() => _NoteDetailState();
}

class _NoteDetailState extends State<_NoteDetailView> {
  String? _text;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await decryptVaultNote(widget.item);
      if (!mounted) return;
      setState(() {
        _text = text;
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back,
                      color: Color(0x80F5EFE6),),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Text(
                  'Note',
                  style: TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xCCF5EFE6)),
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _text ?? '',
                            style: const TextStyle(
                              color: Color(0xFFFBF8F4),
                              fontSize: 16,
                              height: 1.6,
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
