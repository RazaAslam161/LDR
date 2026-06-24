import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/vault/vault_repository.dart';

/// The unlocked vault — personal notes only the owner can see. Shown by
/// VaultGateScreen after a successful PIN/biometric unlock.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key, required this.onLock});
  final VoidCallback onLock;

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  List<VaultItem> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _items = await VaultRepository.items();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
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
                  hintText: 'Just for you — only you can ever read this'),
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
    try {
      await VaultRepository.addNote(text);
      await _load();
    } catch (_) {}
  }

  Future<void> _delete(VaultItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Delete this?'),
        content: const Text('This permanently removes it from your vault.',
            style: TextStyle(color: MilesColors.taupe)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB83A57)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await VaultRepository.deleteItem(item.id);
      await _load();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Private Vault'),
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
            : _items.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Your vault is empty.\nAdd a private note only you can see.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: MilesColors.taupe, height: 1.5),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final item = _items[i];
                      return GestureDetector(
                        onLongPress: () => _delete(item),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: MilesColors.surface1,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color: MilesColors.gilt.withValues(alpha: 0.12)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.content ?? '',
                                  style: const TextStyle(
                                      color: MilesColors.cream50, height: 1.4)),
                              const SizedBox(height: 8),
                              Text(
                                DateFormat('MMM d, y · h:mm a')
                                    .format(item.createdAt),
                                style: const TextStyle(
                                    color: MilesColors.faint, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
