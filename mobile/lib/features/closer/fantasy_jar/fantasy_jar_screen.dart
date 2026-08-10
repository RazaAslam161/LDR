import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/features/closer/closer_load_result.dart';
import 'package:miles/features/closer/fantasy_jar/add_fantasy_screen.dart';
import 'package:miles/features/closer/fantasy_jar/fantasy_jar_repository.dart';

/// Fantasy Jar — a private list of "things I want to try when we're together".
///
/// The magic: tags are HMAC-hashed before storage, so the server never sees
/// plaintext. When both partners independently express interest in the same
/// tag, we surface a soft "you both seem curious about ✨ tag ✨" nudge.
class FantasyJarScreen extends ConsumerStatefulWidget {
  const FantasyJarScreen({super.key});

  @override
  ConsumerState<FantasyJarScreen> createState() => _FantasyJarScreenState();
}

class _FantasyJarScreenState extends ConsumerState<FantasyJarScreen> {
  bool _loading = true;
  String? _error;
  List<FantasyEntry> _mine = const [];
  List<String> _sharedTags = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    final partner = session.partner;
    if (couple == null || me == null || partner == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Link your partner to start your jar.';
        });
      }
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await FantasyJarRepository.ensureSharedKey(session);

      final results = await Future.wait([
        FantasyJarRepository.fetchMyEntries(
          coupleId: couple.id,
          myId: me.id,
        ),
        FantasyJarRepository.fetchMyTagHashes(
          coupleId: couple.id,
          myId: me.id,
        ),
        FantasyJarRepository.fetchPartnerTagHashes(
          coupleId: couple.id,
          partnerId: partner.id,
        ),
      ]);

      final entryResult = results[0] as CloserLoadResult<FantasyEntry>;
      final entries = entryResult.items;
      if (entryResult.hasUnreadable && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(entryResult.unreadableMessage)),
        );
      }
      final myHashes = results[1] as Set<String>;
      final partnerHashes = results[2] as Set<String>;

      // De-hash intersecting hashes back into tag names.
      final tagHashMap = await FantasyJarRepository.buildTagHashMap();
      final shared = <String>[];
      for (final entry in tagHashMap.entries) {
        if (myHashes.contains(entry.value) &&
            partnerHashes.contains(entry.value)) {
          shared.add(entry.key);
        }
      }

      if (!mounted) return;
      setState(() {
        _mine = entries;
        _sharedTags = shared;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _delete(FantasyEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B26),
        title: const Text(
          'Remove this?',
          style: TextStyle(color: Color(0xFFFBF8F4)),
        ),
        content: const Text(
          "This will delete the entry. Your partner won't be notified.",
          style: TextStyle(color: Color(0x99F5EFE6)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await FantasyJarRepository.deleteEntry(entryId: entry.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete: $e')),
      );
    }
  }

  Future<void> _openAdd() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AddFantasyScreen()),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFEF6F58),
        foregroundColor: const Color(0xFF0B0F16),
        onPressed: _loading ? null : _openAdd,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Color(0x80F5EFE6)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Fantasy Jar',
                  style: TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Private · encrypted · tag-matched',
                  style: TextStyle(fontSize: 11, color: Color(0x66F5EFE6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_error != null) {
      return _CenterMessage(
        icon: Icons.lock_outline,
        text: _error!,
        actionLabel: 'Try again',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: const Color(0xFFEF6F58),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
        children: [
          if (_sharedTags.isNotEmpty) ...[
            _buildMatchCard(_sharedTags),
            const SizedBox(height: 20),
          ],
          Text(
            _mine.isEmpty ? 'Your jar' : 'Your jar · ${_mine.length}',
            style: const TextStyle(
              color: Color(0xFFFBF8F4),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 12),
          if (_mine.isEmpty)
            _buildEmpty()
          else
            ..._mine.map(_buildEntryCard),
        ],
      ),
    );
  }

  Widget _buildMatchCard(List<String> tags) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEF6F58), Color(0xFFE0553D)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('✨', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'You both seem curious about',
                  style: TextStyle(
                    color: const Color(0xFF0B0F16).withValues(alpha: 0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: tags
                .map(
                  (t) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B0F16).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(40),
                    ),
                    child: Text(
                      t,
                      style: const TextStyle(
                        color: Color(0xFF0B0F16),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 10),
          const Text(
            'No details are shared — just the matching tag.',
            style: TextStyle(
              color: Color(0xFF0B0F16),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: [
          const Text('🍯', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 16),
          Text(
            'Your jar is empty',
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: const Color(0xFFFBF8F4),
                  fontSize: 20,
                ),
          ),
          const SizedBox(height: 8),
          const Text(
            "Tap + to add a thought. You'll see a soft nudge when your "
            'partner is curious about the same thing.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0x80F5EFE6), height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(FantasyEntry entry) {
    return Dismissible(
      key: ValueKey(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: const Color(0xFFEF6F58).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_outline, color: Color(0xFFEF6F58)),
      ),
      confirmDismiss: (_) async {
        await _delete(entry);
        return false; // we reload instead
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF141B26).withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x1aF5EFE6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.text,
              style: const TextStyle(
                color: Color(0xFFFBF8F4),
                height: 1.5,
              ),
            ),
            if (entry.tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: entry.tags
                    .map(
                      (t) => Text(
                        '#$t',
                        style: const TextStyle(
                          color: Color(0xFFF4937E),
                          fontSize: 11,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              _formatDate(entry.createdAt),
              style: const TextStyle(color: Color(0x66F5EFE6), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }
}

class _CenterMessage extends StatelessWidget {
  const _CenterMessage({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: const Color(0x80F5EFE6)),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0x99F5EFE6), height: 1.5),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
