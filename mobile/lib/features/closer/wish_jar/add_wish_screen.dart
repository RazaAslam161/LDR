import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/partner_key_pin.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/closer/wish_jar/wish_jar_repository.dart';

/// Compose a new Wish Jar entry. Text is freeform; tags come from the
/// fixed taxonomy (max 3). Everything is encrypted + tag-hashed upstream.
class AddWishScreen extends ConsumerStatefulWidget {
  const AddWishScreen({super.key});

  @override
  ConsumerState<AddWishScreen> createState() => _AddWishScreenState();
}

class _AddWishScreenState extends ConsumerState<AddWishScreen> {
  final _controller = TextEditingController();
  final Set<String> _selected = {};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_selected.contains(tag)) {
        _selected.remove(tag);
      } else if (_selected.length < 3) {
        _selected.add(tag);
      }
    });
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Write something first.');
      return;
    }
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    if (couple == null || me == null) {
      setState(() => _error = 'Link your partner first.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await WishJarRepository.ensureSharedKey(session);
      await WishJarRepository.addEntry(
        coupleId: couple.id,
        authorId: me.id,
        text: text,
        tags: _selected.toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      // The screen only pops on success, so _controller still holds the text
      // and Save is the retry — but the message it showed was the raw
      // exception, including the Supabase host on a network failure.
      setState(() {
        _saving = false;
        _error = _friendly(e);
      });
    }
  }

  /// Closer's crypto guards throw `Exception('<sentence the user can act on>')`
  /// (wish_jar_repository.dart, closer_crypto.dart:24,32,46).
  String _friendly(Object e) {
    // By type: the pin's refusal has its own resolution one screen away, and
    // its toString carries no sentence — it fell into "Something went wrong"
    // with a Save-retry that can never succeed.
    if (e is PartnerKeyChangedException) {
      return "Your partner's security key changed. Open Closer to review it.";
    }
    final s = e.toString();
    return s.startsWith('Exception: ')
        ? s.substring('Exception: '.length)
        : friendlyAuthError(e);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
                  Text(
                    'What would you like to do together?',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          color: const Color(0xFFFBF8F4),
                          fontSize: 22,
                        ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    "It's encrypted end-to-end. Only you can read it — and a "
                    'match will surface only when your partner shares the '
                    'same tag.',
                    style: TextStyle(color: Color(0x80F5EFE6), height: 1.5),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _controller,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 600,
                    style: const TextStyle(color: Color(0xFFFBF8F4)),
                    decoration: const InputDecoration(
                      hintText: 'A thought, an idea, a maybe…',
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Text(
                        'Tags',
                        style: TextStyle(
                          color: Color(0xFFFBF8F4),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_selected.length}/3',
                        style: const TextStyle(
                          color: Color(0x66F5EFE6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: kFantasyTaxonomy.map((tag) {
                      final selected = _selected.contains(tag);
                      return GestureDetector(
                        onTap: () => _toggleTag(tag),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? const Color(0xFFEF6F58)
                                : const Color(0xFF141B26),
                            borderRadius: BorderRadius.circular(40),
                            border: Border.all(
                              color: selected
                                  ? const Color(0xFFEF6F58)
                                  : const Color(0x1aF5EFE6),
                            ),
                          ),
                          child: Text(
                            wishTagLabel(tag),
                            style: TextStyle(
                              color: selected
                                  ? const Color(0xFF0B0F16)
                                  : const Color(0xFFF5EFE6),
                              fontSize: 13,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFEF6F58),
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF0B0F16),
                            ),
                          )
                        : const Text('Add to jar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Color(0x80F5EFE6)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'New wish',
                  style: TextStyle(
                    color: Color(0xFFFBF8F4),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Private · end-to-end encrypted',
                  style: TextStyle(fontSize: 11, color: Color(0x66F5EFE6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
