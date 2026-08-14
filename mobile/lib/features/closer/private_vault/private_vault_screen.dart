import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/media/media_decode.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/closer_load_result.dart';
import 'package:miles/features/closer/memory_threads/memory_failure.dart';
import 'package:miles/features/closer/private_vault/private_vault_repository.dart';
import 'package:miles/features/closer/private_vault/vault_media_cache.dart';
import 'package:miles/features/closer/private_vault/vault_media_viewer.dart';


/// Shared Vault — E2EE photo/note storage synced in real-time between partners.
///
/// Implements a buttery-smooth SliverGrid for photos and notes, leveraging
/// an Isolate-based decryption cache to prevent main-thread jank.
class PrivateVaultScreen extends ConsumerStatefulWidget {
  const PrivateVaultScreen({super.key});

  @override
  ConsumerState<PrivateVaultScreen> createState() => _PrivateVaultScreenState();
}

class _PrivateVaultScreenState extends ConsumerState<PrivateVaultScreen> {
  Stream<CloserLoadResult<VaultItem>>? _itemsStream;
  String? _error;
  int _uploadingItems = 0;

  bool get _isUploading => _uploadingItems > 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureKeyAndInitStream();
  }

  Future<void> _ensureKeyAndInitStream() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    if (couple == null || me == null) {
      if (!mounted) return;
      setState(() {
        _error = 'Link your partner to open the Vault.';
      });
      return;
    }

    try {
      await ensureSharedKey(session);
      if (!mounted) return;
      setState(() {
        _itemsStream = PrivateVaultRepository.streamItems(couple.id);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      // Shared with Memory Threads rather than restated: this is the same
      // ensureSharedKey, and two copies of "waiting for your partner" is two
      // that can drift. It moves the day the vault's own vault_failure.dart
      // lands (vault spec §3.6).
      setState(() {
        _error = partnerKeyMessage(e);
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
    } catch (_) {
      _toast("That didn't save. Try again.");
    }
  }

  Future<void> _addPhoto() async {
    final couple = ref.read(sessionProvider).couple;
    final me = ref.read(sessionProvider).profile;
    if (couple == null || me == null) return;

    if (_isUploading) return;

    // Through PhotoPickerService, not a bare ImagePicker.
    //
    // image_picker_android defaults useAndroidPhotoPicker to FALSE, and with it
    // false every pick fires ACTION_GET_CONTENT — the document provider. That
    // is the "it opens the file manager instead of my gallery" complaint, and
    // chat had exactly this bug and exactly this fix. Going through the service
    // also brings the HEIC/ProRAW conversion with it, which the vault would
    // have hit the moment an iPhone photo was chosen.
    final picked = await PhotoPickerService.pickMedia();
    final skipped = PhotoPickerService.takeRejectedFormats();
    if (skipped.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("This phone can't read "
              '${skipped.map((e) => '.$e').join(', ')}'),
        ),
      );
    }
    if (picked.isEmpty) return;

    final ephemeral = await _confirmRetention() ?? true;

    setState(() => _uploadingItems = picked.length);
    for (final item in picked) {
      try {
        final bytes = await item.file.readAsBytes();
        final isVideo = item.isVideo;
        final mimeType = isVideo ? 'video/mp4' : 'image/jpeg';

        await PrivateVaultRepository.insert(
          coupleId: couple.id,
          createdBy: me.id,
          kind: isVideo ? VaultKind.video : VaultKind.photo,
          plaintextBytes: bytes,
          retention: ephemeral ? VaultRetention.ephemeral : VaultRetention.keep,
          mediaMimeType: mimeType,
        );
      } catch (_) {
        _toast("That didn't save. Try again.");
      } finally {
        if (mounted) setState(() => _uploadingItems--);
      }
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
        final confirmed = await _confirm(
          'Ask your partner to confirm the delete? You can force it in 14 days.',
        );
        if (!confirmed) return;
        await _guard(() => PrivateVaultRepository.requestDelete(
              itemId: item.id,
              requestedBy: me.id,
            ));
      case VaultDeleteState.requested:
        if (item.deleteRequestedBy == me.id) {
          final confirmed = await _confirm('Cancel this delete request?');
          if (!confirmed) return;
          await _guard(
              () => PrivateVaultRepository.cancelDeleteRequest(item.id));
        } else {
          final confirmed = await _confirm(
            'Confirm permanent delete? This cannot be undone.',
          );
          if (!confirmed) return;
          await _guard(() => PrivateVaultRepository.hardDelete(
                itemId: item.id,
                deletedBy: me.id,
              ));
        }
      case VaultDeleteState.expired:
        if (item.deleteRequestedBy == me.id) {
          final confirmed = await _confirm(
            '14 days passed with no confirmation. Force delete now?',
          );
          if (!confirmed) return;
          await _guard(() => PrivateVaultRepository.hardDelete(
                itemId: item.id,
                deletedBy: me.id,
              ));
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
    } catch (_) {
      // A delete that 403s used to print the policy name, the SQLSTATE and the
      // hint into a snackbar.
      _toast("That didn't go through. Try again.");
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
  void dispose() {
    unawaited(VaultMediaCache.clear());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              title: 'Shared Vault',
              subtitle: 'Synced instantly. Encrypted end-to-end.',
              onBack: () => context.pop(),
            ),
            if (_isUploading) _UploadBanner(remaining: _uploadingItems),
            Expanded(
              child: _error != null
                  ? _ErrorState(
                      message: _error!,
                      onRetry: _ensureKeyAndInitStream,
                    )
                  : _itemsStream == null
                      ? const Center(child: CircularProgressIndicator())
                      : StreamBuilder<CloserLoadResult<VaultItem>>(
                          stream: _itemsStream,
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              // Never snapshot.error.toString(). A dropped
                              // socket painted a PostgrestException, its
                              // SQLSTATE and its hint across the screen.
                              return _ErrorState(
                                message: "Couldn't open your vault. Try again.",
                                onRetry: _ensureKeyAndInitStream,
                              );
                            }
                            if (!snapshot.hasData) {
                              return const Center(
                                  child: CircularProgressIndicator());
                            }
                            final result = snapshot.data!;
                            if (result.items.isEmpty) {
                              // An empty vault and a vault whose every row
                              // failed to decrypt rendered identically — the
                              // exact failure closer_load_result.dart:5-14 was
                              // written to prevent, with unreadableMessage
                              // still at zero call sites here. Retry is the
                              // real fix for the usual cause, so it keeps one.
                              return result.hasUnreadable
                                  ? _ErrorState(
                                      message: result.unreadableMessage,
                                      onRetry: _ensureKeyAndInitStream,
                                    )
                                  : const _EmptyVault();
                            }
                            return GridView.builder(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 2, vertical: 8),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 2,
                                mainAxisSpacing: 2,
                              ),
                              itemCount: result.items.length,
                              itemBuilder: (context, i) {
                                final item = result.items[i];
                                return _VaultGridItem(
                                  item: item,
                                  onTap: () {
                                    Navigator.of(context).push<void>(
                                      MaterialPageRoute(
                                        builder: (_) => VaultMediaViewer(
                                          items: result.items,
                                          initialIndex: i,
                                        ),
                                        fullscreenDialog: true,
                                      ),
                                    );
                                  },
                                  onLongPress: () => _onDelete(item),
                                );
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton(
            heroTag: 'vault_note',
            onPressed: _isUploading ? null : _addNote,
            backgroundColor: MilesColors.surface2,
            child: const Icon(Icons.edit_outlined, color: Colors.white),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'vault_photo',
            onPressed: _isUploading ? null : _addPhoto,
            backgroundColor: MilesColors.ember,
            child: const Icon(Icons.add_a_photo, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _VaultGridItem extends StatefulWidget {
  const _VaultGridItem({
    required this.item,
    required this.onTap,
    required this.onLongPress,
  });
  final VaultItem item;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_VaultGridItem> createState() => _VaultGridItemState();
}

class _VaultGridItemState extends State<_VaultGridItem> {
  ImageProvider? _provider;
  String? _notePreview;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _VaultGridItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _provider = null;
      _notePreview = null;
      _loading = true;
      _error = null;
      _load();
    }
  }

  Future<void> _load() async {
    // A video tile draws a black rectangle and a play glyph — it never renders
    // the file. It was nevertheless decrypting the preview and WRITING IT TO
    // DISK to arrive at that, so every video in the grid left plaintext behind
    // for a picture nobody sees.
    if (widget.item.kind == VaultKind.video) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (widget.item.kind == VaultKind.photo) {
      try {
        final provider = await VaultMediaCache.photoProvider(
          widget.item,
          original: false,
          decodeWidth: kTileDecodePx,
        ).timeout(const Duration(minutes: 1));
        if (mounted)
          setState(() {
            _provider = provider;
            _loading = false;
          });
      } catch (e) {
        if (mounted)
          setState(() {
            _error = 'Preview unavailable';
            _loading = false;
          });
      }
    } else {
      try {
        final text = await decryptVaultNote(widget.item);
        if (mounted)
          setState(() {
            _notePreview = text;
            _loading = false;
          });
      } catch (e) {
        if (mounted)
          setState(() {
            _error = 'Could not open note';
            _loading = false;
          });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Container(
        color: MilesColors.surface1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_error != null)
              Center(
                child: IconButton(
                  tooltip: _error,
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    _load();
                  },
                  icon: const Icon(Icons.refresh_rounded,
                      color: Color(0xFFE0553D), size: 30),
                ),
              )
            else if (widget.item.kind == VaultKind.video)
              Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Colors.black87),
                  const Center(
                    child: Icon(Icons.play_circle_fill,
                        color: Colors.white, size: 48),
                  ),
                ],
              )
            else if (widget.item.kind == VaultKind.photo)
              _provider != null
                  // From RAM, never a file. The decode is bounded at the tile
                  // width — this used to decode the preview at source
                  // resolution, up to ~48MB of raster per cell for a thumbnail.
                  ? Image(image: _provider!, fit: BoxFit.cover)
                  : _loading
                      ? const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : const SizedBox.shrink()
            else
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Center(
                  child: Text(
                    _notePreview ?? '',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            if (widget.item.deleteState != VaultDeleteState.none)
              Positioned.fill(
                child: Container(
                  // scrim over the decrypted media behind it
                        color: Colors.black.withOpacity(0.5),
                  child: const Center(
                    child: Icon(Icons.delete_sweep, color: Colors.red),
                  ),
                ),
              ),
            if (widget.item.retention == VaultRetention.ephemeral)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.timer, size: 14, color: MilesColors.ember),
              ),
          ],
        ),
      ),
    );
  }
}

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

class _UploadBanner extends StatelessWidget {
  const _UploadBanner({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: MilesColors.surface2,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Encrypting and uploading $remaining ${remaining == 1 ? 'item' : 'items'}…',
            style: const TextStyle(color: MilesColors.cream50, fontSize: 12),
          ),
          const SizedBox(height: 8),
          const LinearProgressIndicator(color: MilesColors.ember),
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
              'Shared Vault',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: const Color(0xFFFBF8F4),
                  ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Synced instantly. Encrypted end-to-end.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0x99F5EFE6),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Use the + buttons to begin.',
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
            const Icon(Icons.lock_outline, color: Color(0xFFEF6F58), size: 36),
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
