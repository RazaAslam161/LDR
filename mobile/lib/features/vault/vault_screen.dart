import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/vault/vault_repository.dart';
import 'package:url_launcher/url_launcher.dart';

/// The unlocked vault — personal notes only the owner can see. Shown by
/// VaultGateScreen after a successful PIN/biometric unlock.
class VaultScreen extends StatefulWidget {
  const VaultScreen({required this.onLock, super.key});
  final VoidCallback onLock;

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  List<VaultItem> _items = const [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _items = await VaultRepository.items();
      _loadError = null;
    } catch (e) {
      // Swallowing this rendered the "Your vault is empty" copy on a network
      // blip — the worst possible lie to tell someone about a vault.
      _loadError = friendlyAuthError(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m, {VoidCallback? onRetry}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m),
        behavior: SnackBarBehavior.floating,
        action: onRetry == null
            ? null
            : SnackBarAction(label: 'Retry', onPressed: onRetry),
      ),
    );
  }

  Future<void> _addNote() async {
    final controller = TextEditingController();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Private note', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              style: const TextStyle(color: MilesColors.cream50),
              decoration: const InputDecoration(
                  hintText: 'Just for you — only you can ever read this',),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save to vault'),
            ),
          ],
        ),
      ),
    );
    if (text == null || text.isEmpty) return;
    await _saveNote(text);
  }

  Future<void> _saveNote(String text) async {
    try {
      await VaultRepository.addNote(text);
      await _load();
    } catch (_) {
      // The sheet's controller is disposed by now, so the typed note exists
      // nowhere but this closure — losing it silently loses it for good.
      _toast("That note didn't save.", onRetry: () => _saveNote(text));
    }
  }

  /// Opens a saved media item. Public couple_media URLs open directly; private
  /// couple_intimate items (stored as `intimate:<path>`) get a fresh signed URL.
  Future<void> _openMedia(VaultItem item) async {
    final c = item.content ?? '';
    String? url;
    if (c.startsWith('intimate:')) {
      url = await ChatRepository.signedVideoUrl(c.substring(9));
    } else if (c.isNotEmpty) {
      url = c;
    }
    var ok = false;
    if (url != null && url.isNotEmpty) {
      try {
        ok = await launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication,);
      } catch (_) {}
    }
    if (!ok) {
      _toast('Link expired — the original message has the latest version');
    }
  }

  Future<void> _delete(VaultItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Delete this?'),
        content: const Text('This permanently removes it from your vault.',
            style: TextStyle(color: MilesColors.taupe),),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB83A57),),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),),
        ],
      ),
    );
    if (ok != true) return;
    await _deleteItem(item);
  }

  Future<void> _deleteItem(VaultItem item) async {
    try {
      await VaultRepository.deleteItem(item.id);
      await _load();
    } catch (_) {
      // The tile stays on screen after a failed delete; say so, or the user
      // reads the still-present row as the delete having been ignored.
      _toast("That didn't delete.", onRetry: () => _deleteItem(item));
    }
  }

  bool _isMedia(VaultItem i) => i.type.startsWith('saved_');

  Widget _buildList() {
    final media = _items.where(_isMedia).toList();
    final notes = _items.where((i) => !_isMedia(i)).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
      children: [
        if (media.isNotEmpty) ...[
          _sectionHeader('Saved media'),
          for (final item in media) ...[
            _mediaTile(item),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 8),
        ],
        if (notes.isNotEmpty) ...[
          _sectionHeader('Notes'),
          for (final item in notes) ...[
            _noteTile(item),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Text(label,
            style: const TextStyle(
                color: MilesColors.gilt,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,),),
      );

  Widget _noteTile(VaultItem item) => GestureDetector(
        onLongPress: () => _delete(item),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: MilesColors.surface1,
            borderRadius: BorderRadius.circular(18),
            border:
                Border.all(color: MilesColors.gilt.withValues(alpha: 0.12)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.content ?? '',
                  style: const TextStyle(
                      color: MilesColors.cream50, height: 1.4,),),
              const SizedBox(height: 8),
              Text(
                DateFormat('MMM d, y · h:mm a').format(item.createdAt),
                style:
                    const TextStyle(color: MilesColors.faint, fontSize: 11),
              ),
            ],
          ),
        ),
      );

  Widget _mediaTile(VaultItem item) {
    final IconData icon;
    final String title;
    switch (item.type) {
      case 'saved_video':
        icon = Icons.videocam_rounded;
        title = 'Saved video';
      case 'saved_voice':
        icon = Icons.mic_rounded;
        title = 'Saved voice note';
      default:
        icon = Icons.photo_rounded;
        title = 'Saved photo';
    }
    return GestureDetector(
      onLongPress: () => _delete(item),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: MilesColors.surface1,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.12)),
        ),
        child: Row(
          children: [
            Icon(icon, color: MilesColors.ember, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: MilesColors.cream50, fontSize: 14,),),
                  const SizedBox(height: 2),
                  Text(item.mediaUrl ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: MilesColors.taupe, fontSize: 11,),),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.open_in_new_rounded,
                  color: MilesColors.gilt,),
              onPressed: () => _openMedia(item),
              tooltip: 'Open',
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Vault'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          IconButton(
            tooltip: 'Lock',
            icon: const Icon(Icons.lock_outline, color: MilesColors.gilt),
            onPressed: widget.onLock,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: MilesColors.blush,
        foregroundColor: MilesColors.cream50,
        onPressed: _addNote,
        icon: const Icon(Icons.add),
        label: const Text('Note'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? _LoadFailed(message: _loadError!, onRetry: _load)
                : _items.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'Your vault is empty.\nAdd a private note only you can see.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: MilesColors.taupe, height: 1.5,),
                          ),
                        ),
                      )
                    : _buildList(),
      ),
    );
  }
}

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: MilesColors.taupe, height: 1.5,),),
              const SizedBox(height: 14),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      );
}
