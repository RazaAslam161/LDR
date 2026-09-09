import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/core/data/media_urls.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/media/media_normalize.dart';
import 'package:miles/core/media/plain_media_cache.dart';
import 'package:miles/core/services/photo_picker_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/drag_select.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:miles/features/vault/change_pin_screen.dart';
import 'package:miles/features/vault/vault_repository.dart';
import 'package:miles/features/vault/vault_thumb_backfill.dart';
import 'package:miles/features/vault/vault_viewer.dart';
import 'package:miles/main.dart';

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
  // What the spinner says. Two owners, two truths: a delete is not a save.
  String _busyLabel = '';
  final Set<String> _selected = <String>{};
  String? _loadError;

  @override
  void initState() {
    super.initState();
    // A WINDOW flag, so this one call also covers VaultViewer: it is pushed
    // above this route (line 318) and this State is not disposed while it is
    // up. Memory Threads and Touch Trace already set it; the vault was the one
    // intimate surface still landing in screenshots and in the recent-apps
    // thumbnail, which is the disguise's whole point.
    SecureScreen.acquire();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    SecureScreen.release();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _items = await VaultRepository.items();
      _loadError = null;
      // ONE batched signing call for every tile AND every original, before a
      // single tile asks. personal_vault is private, so without this each
      // tile paid its own sign round-trip and the grid opened as a wall of
      // glyphs filling in over many seconds — and each tap paid the same
      // round-trip again for the original. The gallery has always done this
      // (MediaUrls.warm); the vault never did.
      //
      // **Split, and only the first half is awaited.** It was one un-awaited
      // call, so `_loading` went false on the next statement and the grid
      // built before `createSignedUrls` landed — which is the whole benefit,
      // thrown away: every visible tile missed `MediaUrls.cached` and signed
      // its own path after all, exactly what the batch exists to prevent.
      // Awaiting the WHOLE set would be the opposite mistake, putting up to
      // 200 originals' signing in front of the first frame for pictures
      // nobody has tapped.
      await MediaUrls.warm(VaultRepository.bucket, [
        for (final i in _items)
          if (i.thumbPath != null) i.thumbPath!,
      ],);
      // The originals follow, off the critical path. The viewer re-signs on
      // its own if it beats this home.
      unawaited(MediaUrls.warm(VaultRepository.bucket, [
        for (final i in _items)
          if (i.storagePath != null) i.storagePath!,
      ],),);
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

  void _toggle(String id) => setState(() {
        if (!_selected.remove(id)) _selected.add(id);
      });

  /// Scrolls the vault while a drag-select runs past the bottom of the screen.
  final ScrollController _scroll = ScrollController();

  /// The media rows the grid is painting, assigned where the grid is built.
  /// A drag reports an INDEX and the ids live here.
  List<VaultItem> _paintedMedia = const [];

  Set<String>? _dragBase;
  bool _dragAdds = true;

  void _dragAnchor(int index) {
    if (index < 0 || index >= _paintedMedia.length) return;
    final id = _paintedMedia[index].id;
    setState(() {
      _dragBase = {..._selected};
      _dragAdds = !_selected.contains(id);
      if (_dragAdds) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  void _dragExtend(int anchor, int extent) {
    final base = _dragBase;
    if (base == null) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(base);
      for (final i in dragSelectSpan(anchor, extent)) {
        if (i < 0 || i >= _paintedMedia.length) continue;
        final id = _paintedMedia[i].id;
        if (_dragAdds) {
          _selected.add(id);
        } else {
          _selected.remove(id);
        }
      }
    });
  }

  void _dragEnd() => _dragBase = null;

  /// Deletes everything selected, in one confirmation.
  ///
  /// Long-pressing each item and confirming one at a time is the whole reason
  /// clearing a vault felt like a chore.
  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: Text(ids.length == 1 ? 'Delete this?' : 'Delete ${ids.length}?'),
        content: Text(
          ids.length == 1
              ? 'This permanently removes it from your vault.'
              : 'This permanently removes them from your vault.',
          style: const TextStyle(color: MilesColors.taupe),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _busyLabel = 'Deleting…';
    });
    var failed = 0;
    for (final id in ids) {
      try {
        await VaultRepository.deleteItem(id);
      } catch (e) {
        // Counted, not swallowed: a delete that quietly failed leaves the user
        // believing something is gone when it is still there.
        failed++;
        debugPrint('[vault] delete failed: ${e.runtimeType}');
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
    });
    if (failed > 0) {
      _toast(failed == ids.length
          ? 'Nothing could be deleted — check your connection.'
          : "$failed of ${ids.length} couldn't be deleted.");
    }
    await _load();
  }

  /// Opens the change-PIN flow and reports the outcome.
  ///
  /// Nothing about the vault's contents changes, so nothing here re-locks or
  /// re-reads: the PIN is a gate and the encryption key is derived from the
  /// device seed, not from it. The snackbar exists because a silent success on
  /// a security control is indistinguishable from a button that did nothing.
  Future<void> _changePin() async {
    final changed = await ChangePinScreen.open(context);
    if (changed != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Vault PIN changed')),
    );
  }

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

  /// Copies the picked files INTO the vault, under this user's own folder — it
  /// does not bookmark them where they already live.
  Future<void> _addMedia() async {
    // The picker is a full-screen system window: Android reports `paused`, the
    // disguise cover raises, the vault gate auto-locks, and this widget is
    // disposed while the picker is still up. The files then came back to a
    // `!mounted` check and were dropped without a byte uploaded or a word
    // logged. Every other picker in the app sets this; the vault never did.
    final List<XFile> picked;
    MilesApp.systemOverlayActive = true;
    try {
      // The one picker in the app that skipped the system Photo Picker flag —
      // so the vault opened the DOCUMENT provider (a file manager) where every
      // other surface opened the gallery.
      PhotoPickerService.useSystemGallery();
      picked = await ImagePicker().pickMultipleMedia();
    } catch (e, st) {
      // Was outside the try below, so a PlatformException escaped _addMedia,
      // escaped the unawaited _addSheet, and showed the user nothing at all.
      MilesApp.systemOverlayActive = false;
      ErrorReporter.report(e, st, kind: 'vault');
      if (mounted) _toast("Couldn't open the picker.");
      return;
    }
    MilesApp.systemOverlayActive = false;
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _busyLabel = 'Saving to your vault…';
    });
    var failed = 0;
    for (final file in picked) {
      try {
        var mime = _mimeOf(file.path, file.mimeType);
        final isVideo = mime.startsWith('video/');

        Uint8List bytes;
        if (isVideo) {
          bytes = await file.readAsBytes();
        } else {
          // The step this was missing. A modern Android camera writes HEIC, and
          // the Dart `image` package cannot decode it — deriveImage returns
          // null and the save throws before a byte is uploaded. toSendable
          // converts through the PLATFORM codec, which does read it.
          final ready = await MediaNormalize.toSendable(File(file.path));
          if (ready == null) {
            failed++;
            ErrorReporter.report(
              StateError('vault: undecodable ${MediaNormalize.extensionOf(file.path)}'),
              StackTrace.current,
              kind: 'vault',
            );
            continue;
          }
          bytes = await ready.readAsBytes();
          if (!MediaNormalize.isSupported(file.path)) mime = 'image/jpeg';
        }

        await VaultRepository.saveMedia(
          bytes: bytes,
          mimeType: mime,
          label: file.name,
          type: isVideo ? 'saved_video' : 'saved_photo',
        );
      } catch (e, st) {
        // Reported to Diag, not just debugPrint: release builds compile
        // debugPrint out, so the last version of this counted a failure the
        // user could see and left nothing anyone could diagnose.
        failed++;
        ErrorReporter.report(e, st, kind: 'vault');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failed > 0) {
      _toast(failed == picked.length
          ? 'Nothing could be saved — check your connection.'
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
    } catch (e, st) {
      // The sheet's controller is disposed by now, so the typed note exists
      // nowhere but this closure — losing it silently loses it for good.
      // Reported too: this was the one vault write whose failure left no row
      // in client_errors, which is indistinguishable from "never failed".
      ErrorReporter.report(e, st, kind: 'vault');
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
    if (item.isDeadBookmark) {
      _toast('Saved as a link that has since expired — re-save it from the '
          'original message.');
      return;
    }
    final owned = _items.where((i) => !i.isDeadBookmark).toList();
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

  /// SLIVERS, not a ListView of children with a shrinkWrap grid inside.
  ///
  /// The old shape built every tile and every note before the first frame —
  /// `shrinkWrap: true` with `NeverScrollableScrollPhysics` lays the whole grid
  /// out at once — and each `_VaultTile.initState` starts its own sign,
  /// download and decrypt. A vault of any size therefore opened by firing one
  /// network chain per item simultaneously, for items nobody had scrolled to.
  /// A SliverGrid builds only what is on screen (plus the viewport's cache
  /// extent), so the fetches follow the eye.
  Widget _buildList() {
    final media = _items.where(_isMedia).toList();
    final notes = _items.where((i) => !_isMedia(i)).toList();
    _paintedMedia = media;
    return DragSelect(
      scroll: _scroll,
      onAnchor: _dragAnchor,
      onExtend: _dragExtend,
      onEnd: _dragEnd,
      child: CustomScrollView(
      controller: _scroll,
      slivers: [
        if (media.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverToBoxAdapter(child: _sectionHeader('Saved media')),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            // Square cells fixed by the delegate, so a tile occupies its final
            // shape before any bytes arrive and nothing below it reflows as
            // pictures land.
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 3,
                mainAxisSpacing: 3,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, i) => DragSelectItem(
                  index: i,
                  child: _VaultTile(
                    // Keyed by id: the list re-sorts and re-filters on every
                    // save and delete, and an index-matched element would hand
                    // one item's decrypted tile to another's row.
                    key: ValueKey(media[i].id),
                    item: media[i],
                    selected: _selected.contains(media[i].id),
                    selecting: _selected.isNotEmpty,
                    onTap: () => _selected.isEmpty
                        ? _openMedia(media[i])
                        : _toggle(media[i].id),
                  ),
                ),
                childCount: media.length,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
        if (notes.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverToBoxAdapter(child: _sectionHeader('Notes')),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _noteTile(notes[i]),
                ),
                childCount: notes.length,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 100)),
      ],
      ),
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
      appBar: _selected.isNotEmpty
          ? AppBar(
              title: Text('${_selected.length} selected'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel',
                onPressed: () => setState(_selected.clear),
              ),
              actions: [
                IconButton(
                  tooltip: 'Select all',
                  icon: const Icon(Icons.select_all_rounded,
                      color: MilesColors.gilt,),
                  onPressed: () => setState(() => _selected
                    ..clear()
                    ..addAll(_items.where(_isMedia).map((i) => i.id)),),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline_rounded,
                      color: MilesColors.blush,),
                  onPressed: _deleteSelected,
                ),
              ],
            )
          : AppBar(
        title: const Text('Vault'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          // Here rather than in Settings: the user is already past the gate,
          // which is the only place they can be to change the PIN at all, and
          // a control for a vault that lives outside the vault is one nobody
          // finds.
          IconButton(
            tooltip: 'Change PIN',
            icon: const Icon(Icons.password_rounded, color: MilesColors.gilt),
            onPressed: _changePin,
          ),
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
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    Text(_busyLabel,
                        style: const TextStyle(
                            color: MilesColors.taupe, fontSize: 12,),),
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
    required this.selected,
    required this.selecting,
    required this.onTap,
    super.key,
  });

  final VaultItem item;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

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
    if (!_paintWarm()) _load();
  }

  /// Paints an item this process has already resolved, WITHOUT an await.
  ///
  /// `_load` is a Future even when nothing has to be fetched — the URL is a map
  /// lookup and the provider is a constructor — and an await anywhere on that
  /// path costs one frame with `_provider == null`. That frame is the glyph
  /// flashing over a photograph the phone is already holding, on every scroll
  /// that recycles the cell and every time the vault is opened again. Chat's
  /// pager removed the identical frame the identical way, by reading
  /// MediaUrls.cached before reaching for MediaUrls.sign.
  ///
  /// True means the tile is finished and [_load] has nothing left to do.
  bool _paintWarm() {
    final legacy = widget.item.legacyIntimatePath;
    if (legacy != null) {
      if (widget.item.isVideo || legacy.toLowerCase().endsWith('.mp4')) {
        return false;
      }
      // The same path signedVideoUrl would sign, so the same cache entry.
      final p = PlainMediaCache.warm(
          privateBucket, MediaUrls.toPath(privateBucket, legacy),);
      if (p == null) return false;
      _provider = p;
      return true;
    }
    final path = widget.item.gridPath;
    if (path == null) return false;
    final p = path.endsWith('.enc')
        ? EncryptedMediaCache.warmTileProvider(
            bucket: VaultRepository.bucket, path: path,)
        : PlainMediaCache.warm(VaultRepository.bucket, path);
    if (p == null) return false;
    _provider = p;
    return true;
  }

  @override
  void didUpdateWidget(_VaultTile old) {
    super.didUpdateWidget(old);
    // Cells are recycled. Without this the tile keeps painting the previous
    // item's picture until the new one resolves.
    if (old.item.id != widget.item.id) {
      _provider = null;
      _failed = false;
      if (!_paintWarm()) _load();
    }
  }

  @override
  void dispose() {
    _mounted = false;
    super.dispose();
  }

  Future<void> _load() async {
    final legacy = widget.item.legacyIntimatePath;
    if (legacy != null) {
      // Plaintext in the couple's bucket, so a signed URL rather than a
      // decrypt. Showing an icon for these was the regression: the bytes are
      // still there and still readable.
      if (widget.item.isVideo || legacy.toLowerCase().endsWith('.mp4')) return;
      try {
        final url = await ChatRepository.signedVideoUrl(legacy);
        if (url != null && _mounted) {
          setState(() => _provider = PlainMediaCache.provider(
                privateBucket, MediaUrls.toPath(privateBucket, legacy), url,),);
        }
      } catch (e) {
        if (_mounted) setState(() => _failed = true);
      }
      return;
    }
    final path = widget.item.gridPath;
    if (path == null) {
      // A saved VIDEO with no poster. Every one of them is in this state —
      // the save path only ever derived a tile for images — so the glyph was
      // not a fallback, it was the only thing this branch could ever paint.
      // Heal it once from the video the vault already owns, then repaint.
      if (VaultThumbBackfill.wants(widget.item)) {
        final healed = await VaultThumbBackfill.heal(widget.item);
        if (healed == null || !_mounted) return;
        final url = await MediaUrls.sign(VaultRepository.bucket, healed);
        if (url == null || !_mounted) return;
        setState(() => _provider =
            PlainMediaCache.provider(VaultRepository.bucket, healed, url),);
      }
      return; // audio: the glyph IS the preview, and always was
    }
    if (!path.endsWith('.enc')) {
      // The gallery mechanism verbatim: the screen's _load already
      // batch-signed every path, so this is a cache hit, not a round trip.
      try {
        final url = MediaUrls.cached(VaultRepository.bucket, path) ??
            await MediaUrls.sign(VaultRepository.bucket, path);
        if (!_mounted) return;
        if (url != null) {
          // NOT NetworkImage. That one has no disk cache at all and is keyed on
          // a URL whose token rotates daily, so every eviction and every
          // morning was a fresh download of a picture already on the phone.
          setState(() => _provider =
              PlainMediaCache.provider(VaultRepository.bucket, path, url),);
        } else {
          setState(() => _failed = true);
        }
      } catch (e, st) {
        ErrorReporter.report(e, st, kind: 'vault-tile');
        if (_mounted) setState(() => _failed = true);
      }
      return;
    }
    try {
      final p = await EncryptedMediaCache.tileProvider(
        bucket: VaultRepository.bucket,
        path: path,
        associatedData: widget.item.thumbPath != null
            ? VaultRepository.thumbAdFor(widget.item.id)
            : VaultRepository.fullAdFor(widget.item.id),
        keyOverride: await CryptoCore.exportVaultKeyBytes(),
      );
      if (_mounted) setState(() => _provider = p);
    } catch (e, st) {
      // Named, finally. This catch swallowed the grid's whole failure mode —
      // black tiles reached the owner three builds running with nothing in
      // client_errors to say whether the sign, the download, the decrypt or
      // the decode was the half that died.
      ErrorReporter.report(e, st, kind: 'vault-tile');
      if (_mounted) setState(() => _failed = true);
    }
  }

  /// One report per tile instance: a decode failure reruns the errorBuilder
  /// on every rebuild, and sixty reports a second is how the cap gets spent
  /// on one broken picture.
  bool _decodeReported = false;

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
                errorBuilder: (_, err, st) {
                  // The decrypt SUCCEEDED and the plaintext would not decode
                  // as an image — a different disease from every failure the
                  // catch above can see, and it was rendered identically.
                  if (!_decodeReported) {
                    _decodeReported = true;
                    ErrorReporter.report(err, st, kind: 'vault-tile-decode');
                  }
                  return Center(
                    child: Icon(_glyph, color: MilesColors.faint, size: 26),
                  );
                },
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
            if (widget.item.isDeadBookmark)
              const Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.link_off_rounded,
                      color: MilesColors.faint, size: 14,),
                ),
              ),
            if (widget.selecting)
              Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    widget.selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: widget.selected
                        ? MilesColors.ember
                        : Colors.white70,
                    size: 20,
                  ),
                ),
              ),
            if (widget.selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: MilesColors.ember.withValues(alpha: 0.28),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
