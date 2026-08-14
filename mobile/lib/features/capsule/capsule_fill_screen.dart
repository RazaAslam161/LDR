import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/capsule/capsule_repository.dart';
import 'package:miles/main.dart' show MilesApp;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Add notes / photos / voice memos to a SEALED capsule. Everything you add
/// stays hidden (you can't read items back) until the capsule unlocks — so
/// the contents are a genuine surprise for the reunion.
class CapsuleFillScreen extends ConsumerStatefulWidget {
  const CapsuleFillScreen({required this.capsule, super.key});
  final Capsule capsule;

  @override
  ConsumerState<CapsuleFillScreen> createState() => _CapsuleFillScreenState();
}

class _CapsuleFillScreenState extends ConsumerState<CapsuleFillScreen> {
  final _picker = ImagePicker();
  Map<CapsuleItemType, int> _summary = const {};
  bool _loading = true;
  bool _busy = false;

  Capsule get _capsule => widget.capsule;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    try {
      final s = await CapsuleRepository.sealSummary(_capsule.id);
      if (mounted) setState(() => _summary = s);
    } catch (_) {
      // _SealedSilhouettes draws one shape per item, so a swallowed failure
      // rendered the capsule as holding nothing.
      _toast("Couldn't count what's already inside.");
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
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
            Text('Write a note',
                style: Theme.of(ctx).textTheme.titleLarge,),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              style: const TextStyle(color: MilesColors.cream50),
              decoration:
                  const InputDecoration(hintText: 'Something to find later…'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Seal it in'),
            ),
          ],
        ),
      ),
    );
    if (text == null || text.isEmpty) return;
    setState(() => _busy = true);
    try {
      await CapsuleRepository.addNote(_capsule.id, text);
      _toast('Note sealed in 💌');
      await _loadSummary();
    } catch (e) {
      _toast('Could not add note.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addPhoto() async {
    XFile? file;
    MilesApp.systemOverlayActive = true;
    try {
      file =
          await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    } finally {
      MilesApp.systemOverlayActive = false;
    }
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await file.readAsBytes();
      final ext = file.name.split('.').last.toLowerCase();
      await CapsuleRepository.addMedia(
        coupleId: _capsule.coupleId,
        capsuleId: _capsule.id,
        type: CapsuleItemType.photo,
        bytes: bytes,
        fileExtension: ext == 'png' ? 'png' : 'jpg',
        contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
      );
      _toast('Photo sealed in 📷');
      await _loadSummary();
    } catch (e) {
      _toast('Could not add photo.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addVoice() async {
    final rec = AudioRecorder();
    if (!await rec.hasPermission()) {
      _toast('Microphone permission is needed for voice memos.');
      await rec.dispose();
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/capsule_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(const RecordConfig(), path: path);

    // Three awaits sit between the tap and this sheet — a permission prompt, a
    // temp-directory lookup and starting the recorder. Leaving the screen
    // during any of them disposes this State, and opening a sheet on a dead
    // context throws. The recorder is already running by now, so it has to be
    // stopped rather than abandoned.
    if (!mounted) {
      await rec.stop();
      await rec.dispose();
      return;
    }

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: MilesColors.surface1,
      builder: (ctx) => _RecordingSheet(),
    );
    final outPath = await rec.stop();
    await rec.dispose();

    if (saved != true || outPath == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await File(outPath).readAsBytes();
      await CapsuleRepository.addMedia(
        coupleId: _capsule.coupleId,
        capsuleId: _capsule.id,
        type: CapsuleItemType.voice,
        bytes: bytes,
        fileExtension: 'm4a',
        contentType: 'audio/mp4',
      );
      _toast('Voice memo sealed in 🎙️');
      await _loadSummary();
    } catch (e) {
      _toast('Could not add voice memo.');
    }
    if (mounted) setState(() => _busy = false);
  }

  int get _total => _summary.values.fold(0, (a, b) => a + b);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Fill the capsule'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(_capsule.title,
                style: Theme.of(context).textTheme.displaySmall,),
            const SizedBox(height: 6),
            const Text(
              "Tuck in little surprises. You won't be able to peek — "
              'they stay sealed until it opens.',
              style: TextStyle(color: MilesColors.taupe, height: 1.5),
            ),
            const SizedBox(height: 24),
            _SealedSilhouettes(loading: _loading, total: _total),
            const SizedBox(height: 28),
            _AddButton(
              emoji: '💌',
              label: 'Write a note',
              onTap: _busy ? null : _addNote,
            ),
            _AddButton(
              emoji: '📷',
              label: 'Add a photo',
              onTap: _busy ? null : _addPhoto,
            ),
            _AddButton(
              emoji: '🎙️',
              label: 'Record a voice memo',
              onTap: _busy ? null : _addVoice,
            ),
            if (_busy) ...[
              const SizedBox(height: 20),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
    );
  }
}

class _SealedSilhouettes extends StatelessWidget {
  const _SealedSilhouettes({required this.loading, required this.total});
  final bool loading;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: MilesColors.blush.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          Text(
            loading ? '…' : '$total sealed inside',
            style: const TextStyle(
                color: MilesColors.cream50,
                fontSize: 16,
                fontWeight: FontWeight.w600,),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              for (var i = 0; i < (total.clamp(0, 12)); i++)
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      MilesColors.blush.withValues(alpha: 0.4),
                      MilesColors.blush.withValues(alpha: 0.05),
                    ],),
                    border: Border.all(
                        color: MilesColors.gilt.withValues(alpha: 0.2),),
                  ),
                  child: const Icon(Icons.lock,
                      size: 14, color: MilesColors.starlight,),
                ),
              if (total == 0)
                const Text('Nothing yet — add the first thing 💫',
                    style: TextStyle(color: MilesColors.taupe),),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.emoji, required this.label, this.onTap});
  final String emoji;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: MilesColors.surface2,
            borderRadius: BorderRadius.circular(18),
            border:
                Border.all(color: MilesColors.gilt.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 14),
              Text(label,
                  style: const TextStyle(
                      color: MilesColors.cream50,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,),),
              const Spacer(),
              const Icon(Icons.add, color: MilesColors.ember),
            ],
          ),
        ),
      ),
    );
  }
}

/// Modal shown while recording a voice memo (timer + stop).
class _RecordingSheet extends StatefulWidget {
  @override
  State<_RecordingSheet> createState() => _RecordingSheetState();
}

class _RecordingSheetState extends State<_RecordingSheet> {
  Timer? _t;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1),
        (_) => setState(() => _seconds++),);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  String get _elapsed {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mic, color: MilesColors.blush, size: 44),
          const SizedBox(height: 12),
          Text('Recording…  $_elapsed',
              style: const TextStyle(
                  color: MilesColors.cream50, fontSize: 16,),),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Stop & seal'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
