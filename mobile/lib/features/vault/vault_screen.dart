import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/features/vault/vault_repository.dart';
import 'package:miles/features/vault/vault_viewer.dart';

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
  bool _busy = false;
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


  /// Media first, because that is what a vault mostly holds.
  Future<void> _addSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MilesColors.surface1,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: MilesColors.ember,),
              title: const Text('Photos or video',
                  style: TextStyle(color: MilesColors.cream50),),
              onTap: () => Navigator.pop(ctx, 'media'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.edit_note_rounded, color: MilesColors.ember),
              title: const Text('Note',
                  style: TextStyle(color: MilesColors.cream50),),
              onTap: () => Navigator.pop(ctx, 'note'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'note') return _addNote();
    if (choice == 'media') return _addMedia();
  }

  /// Copies the picked files INTO the vault, encrypted, under this user's own
  /// folder — it does not bookmark them where they already live.
  Future<void> _addMedia() async {
    final picked = await ImagePicker().pickMultipleMedia();
    if (picked.isEmpty || !mounted) return;
    setState(() => _busy = true);
    var failed = 0;
    for (final file in picked) {
      try {
        final bytes = await file.readAsBytes();
        await VaultRepository.saveMedia(
          bytes: bytes,
          mimeType: _mimeOf(file.path, file.mimeType),
          label: file.name,
          type: _mimeOf(file.path, file.mimeType).startsWith('video/')
              ? 'saved_video'
              : 'saved_photo',
        );
      } catch (e) {
        // Counted and reported, never swallowed: a save that silently did
        // nothing is the worst outcome for something the user believes is now
        // kept safe.
        failed++;
        debugPrint('[vault] save failed: ${e.runtimeType}');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failed > 0) {
      _toast(failed == picked.length
          ? "Nothing could be saved — check your connection."
          : "$failed of ${picked.length} couldn't be saved.");
    }
    await _load();
  }

  /// XFile.mimeType is usually null on Android, so the extension decides.
  static String _mimeOf(String path, String? reported) {
    if (reported != null && reported.contains('/')) return reported;
    final ext = path.toLowerCase().split('.').last;
    return switch (ext) {
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'm4a' || 'aac' => 'audio/mp4',
      'mp3' => 'audio/mpeg',
      _ => 'image/jpeg',
    };
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
  /// Opens the item in-app. Nothing here ever reaches a browser.
  Future<void> _openMedia(VaultItem item) async {
    // A legacy bookmark row has no bytes of its own — it points into the
    // couple's shared bucket, or at a signed URL that has almost certainly
    // expired. There is nothing to show and no honest way to pretend there is.
    if (!item.isOwned) {
      _toast('Saved before this vault kept its own copy — re-save it from the '
          'original message.');
      return;
    }
    final owned = _items.where((i) => i.isOwned).toList();
    final index = owned.indexWhere((i) => i.id == item.id);
    if (index < 0) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VaultViewer(items: owned, initialIndex: index),
      ),
    );
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
          // A grid, not a stack of rows with an "open" button. Square cells
          // fixed by the delegate, so a tile occupies its final shape before
          // any bytes arrive and nothing below it reflows as pictures land.
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 3,
              mainAxisSpacing: 3,
            ),
            itemCount: media.length,
            itemBuilder: (_, i) => _VaultTile(
              item: media[i],
              onTap: () => _openMedia(media[i]),
              onLongPress: () => _delete(media[i]),
            ),
          ),
          const SizedBox(height: 16),
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
        onPressed: _addSheet,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: SafeArea(
        child: _busy
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 14),
                    Text('Encrypting and saving…',
                        style:
                            TextStyle(color: MilesColors.taupe, fontSize: 12),),
                  ],
                ),
              )
            : _loading
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

/// One square cell in the vault grid.
///
/// Paints the thumbnail object, never the original: a 3-wide grid decoding
/// full-size pictures is how a gallery ends up feeling like it is still
/// loading long after it has finished.
class _VaultTile extends StatefulWidget {
  const _VaultTile({
    required this.item,
    required this.onTap,
    required this.onLongPress,
  });

  final VaultItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_VaultTile> createState() => _VaultTileState();
}

class _VaultTileState extends State<_VaultTile> {
  ImageProvider? _provider;
  bool _failed = false;
  bool _mounted = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_VaultTile old) {
    super.didUpdateWidget(old);
    // Cells are recycled. Without this the tile keeps painting the previous
    // item's picture until the new one resolves.
    if (old.item.id != widget.item.id) {
      _provider = null;
      _failed = false;
      _load();
    }
  }

  @override
  void dispose() {
    _mounted = false;
    super.dispose();
  }

  Future<void> _load() async {
    final path = widget.item.gridPath;
    if (path == null) return; // video/audio, or a legacy row: icon only
    try {
      final p = await EncryptedMediaCache.tileProvider(
        bucket: VaultRepository.bucket,
        path: path,
        associatedData: widget.item.thumbPath != null
            ? VaultRepository.thumbAdFor(widget.item.id)
            : VaultRepository.fullAdFor(widget.item.id),
      );
      if (_mounted) setState(() => _provider = p);
    } catch (e) {
      if (_mounted) setState(() => _failed = true);
    }
  }

  IconData get _glyph => switch (widget.item.type) {
        'saved_video' => Icons.play_circle_outline_rounded,
        'saved_voice' => Icons.graphic_eq_rounded,
        _ => Icons.photo_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: MilesColors.surface2),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (provider != null)
              Image(
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // Zero fade-out: the default composites two frames per
                // recycled cell for a full second during a scroll.
                errorBuilder: (_, __, ___) => Center(
                  child: Icon(_glyph, color: MilesColors.faint, size: 26),
                ),
              )
            else
              Center(
                child: Icon(
                  _failed ? Icons.broken_image_outlined : _glyph,
                  color: MilesColors.faint,
                  size: 26,
                ),
              ),
            // Video and voice keep a badge even once a poster paints, so the
            // grid says what a cell will do before it is tapped.
            if (widget.item.isVideo || widget.item.isAudio)
              const Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.play_circle_fill_rounded,
                      color: Colors.white70, size: 18,),
                ),
              ),
            if (!widget.item.isOwned)
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.link_off_rounded,
                      color: MilesColors.faint, size: 14,),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
