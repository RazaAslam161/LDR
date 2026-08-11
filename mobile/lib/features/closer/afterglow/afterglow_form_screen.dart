import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/features/closer/afterglow/afterglow_screen.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/main.dart' show MilesApp;

/// "Start a moment" form for Afterglow. The current partner writes their
/// gratitude (+ optional photo); on "seal", the entry is persisted with the
/// partner's side left null. When the partner opens it later, they get a
/// "complete the moment" prompt and seal the entry.
///
/// For simplicity in v1 we seal immediately on a single partner's submission —
/// the spec's "both partners enter gratitude together" assumes both are online
/// at the same moment. We approximate that by allowing a follow-up complete
/// step when the partner next opens the entry. The sealed_at column is set
/// here, which the list view requires; the partner can still patch in their
/// own side later via [AfterglowRepository.completeAndSeal] (which is why that
/// method does an `update`, not an insert).
class AfterglowFormScreen extends ConsumerStatefulWidget {
  const AfterglowFormScreen({super.key});

  @override
  ConsumerState<AfterglowFormScreen> createState() =>
      _AfterglowFormScreenState();
}

class _AfterglowFormScreenState extends ConsumerState<AfterglowFormScreen> {
  final _controller = TextEditingController();
  Uint8List? _photo;
  bool _ephemeral = true;
  bool _sealing = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    XFile? xfile;
    MilesApp.systemOverlayActive = true;
    try {
      xfile =
          await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    } finally {
      MilesApp.systemOverlayActive = false;
    }
    if (xfile == null) return;
    final bytes = await xfile.readAsBytes();
    if (!mounted) return;
    setState(() => _photo = bytes);
  }

  Future<void> _seal() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Write a line first.');
      return;
    }
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    final partner = session.partner;
    if (couple == null || me == null || partner == null) {
      setState(() => _error = 'Link your partner first.');
      return;
    }

    setState(() {
      _sealing = true;
      _error = null;
    });

    try {
      await ensureSharedKey(session);
      await AfterglowRepository.startEntry(
        coupleId: couple.id,
        myId: me.id,
        partnerId: partner.id,
        gratitude: text,
        photoBytes: _photo,
        ephemeral: _ephemeral,
      );
      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sealing = false;
        _error = e.toString().replaceFirst('Exception: ', '');
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
            _Header(
              title: 'A moment',
              subtitle: 'What are you grateful for, right now?',
              onBack: () => context.pop(),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _controller,
                      minLines: 4,
                      maxLines: 8,
                      style: const TextStyle(
                        color: Color(0xFFFBF8F4),
                        height: 1.5,
                      ),
                      decoration: const InputDecoration(
                        hintText:
                            "One line about what you're grateful for tonight…",
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_photo != null)
                      Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.memory(
                              _photo!,
                              height: 180,
                              width: double.infinity,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: GestureDetector(
                              onTap: () => setState(() => _photo = null),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(
                                  // A scrim over the photo it sits on — the
                                  // X has to read against any picture.
                                  color: Color(0xCC000000),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.close,
                                  size: 16,
                                  color: Color(0xFFFBF8F4),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: _pickPhoto,
                        icon: const Icon(Icons.photo_outlined, size: 18),
                        label: const Text('Add a photo (optional)'),
                      ),
                    const SizedBox(height: 20),
                    _retentionToggle,
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
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _sealing ? null : _seal,
                      child: _sealing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF0B0F16),
                              ),
                            )
                          : const Text('Seal'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Sealing writes it, encrypted, to your shared timeline.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0x66F5EFE6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget get _retentionToggle {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF141B26),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _ephemeral = true),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _ephemeral
                      ? const Color(0xFFEF6F58)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(40),
                ),
                child: Text(
                  'Ephemeral',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _ephemeral
                        ? const Color(0xFF0B0F16)
                        : const Color(0x99F5EFE6),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _ephemeral = false),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: !_ephemeral
                      ? const Color(0xFFEF6F58)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(40),
                ),
                child: Text(
                  'Keep',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: !_ephemeral
                        ? const Color(0xFF0B0F16)
                        : const Color(0x99F5EFE6),
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ],
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
