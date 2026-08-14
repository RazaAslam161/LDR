import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/features/closer/closer_crypto.dart';
import 'package:miles/features/closer/memory_threads/memory_failure.dart';
import 'package:miles/features/closer/memory_threads/memory_thread_repository.dart';
import 'package:miles/main.dart' show MilesApp;

/// "Propose a memory" form. Encrypts title + note + photo on-device before
/// inserting into `memory_threads` with state = `proposed`. Awaits partner's
/// accept on their next open of the timeline.
class ProposeMemoryScreen extends ConsumerStatefulWidget {
  const ProposeMemoryScreen({super.key});

  @override
  ConsumerState<ProposeMemoryScreen> createState() =>
      _ProposeMemoryScreenState();
}

class _ProposeMemoryScreenState extends ConsumerState<ProposeMemoryScreen> {
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  DateTime _date = DateTime.now();
  Uint8List? _photo;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFEF6F58),
            onPrimary: Color(0xFF0B0F16),
            surface: Color(0xFF141B26),
            onSurface: Color(0xFFFBF8F4),
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickPhoto() async {
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
    if (!mounted) return;
    setState(() => _photo = bytes);
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give it a title.');
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
      await ensureSharedKey(session);
      await MemoryThreadRepository.propose(
        coupleId: couple.id,
        proposer: me.id,
        title: title,
        happenedOn: _date,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
        photoBytes: _photo,
      );
      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = partnerKeyMessage(e);
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
              title: 'Propose a memory',
              subtitle: 'Your partner will be asked to accept it.',
              onBack: () => context.pop(),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _titleController,
                      style: const TextStyle(color: Color(0xFFFBF8F4)),
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        hintText: 'That night in Lisbon…',
                      ),
                    ),
                    const SizedBox(height: 14),
                    InkWell(
                      onTap: _pickDate,
                      borderRadius: BorderRadius.circular(16),
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'When',
                          suffixIcon: Icon(
                            Icons.calendar_today_outlined,
                            color: Color(0x80F5EFE6),
                            size: 18,
                          ),
                        ),
                        child: Text(
                          _formatDate(_date),
                          style: const TextStyle(color: Color(0xFFFBF8F4)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _noteController,
                      maxLines: 4,
                      style: const TextStyle(
                        color: Color(0xFFFBF8F4),
                        height: 1.5,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Note (optional)',
                        hintText: 'What you want to remember about it…',
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
                      onPressed: _saving ? null : _submit,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF0B0F16),
                              ),
                            )
                          : const Text('Propose'),
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

  String _formatDate(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
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
