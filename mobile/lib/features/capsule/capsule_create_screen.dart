import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/services/sound/cue.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/capsule/capsule_repository.dart';

class CapsuleCreateScreen extends ConsumerStatefulWidget {
  const CapsuleCreateScreen({super.key});

  @override
  ConsumerState<CapsuleCreateScreen> createState() =>
      _CapsuleCreateScreenState();
}

class _CapsuleCreateScreenState extends ConsumerState<CapsuleCreateScreen> {
  final _title = TextEditingController();
  CapsuleUnlockMode _mode = CapsuleUnlockMode.proximity;
  DateTime? _date;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  bool get _needsDate =>
      _mode == CapsuleUnlockMode.date || _mode == CapsuleUnlockMode.both;

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 30)),
      firstDate: now,
      lastDate: DateTime(now.year + 10),
      helpText: 'When should it open?',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 20, minute: 0),
      helpText: 'At what time?',
    );
    final t = time ?? const TimeOfDay(hour: 20, minute: 0);
    setState(() =>
        _date = DateTime(date.year, date.month, date.day, t.hour, t.minute),);
  }

  Future<void> _save() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Give your capsule a name.');
      return;
    }
    if (_needsDate && _date == null) {
      setState(() => _error = 'Pick the date it should open.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      MilesSound.cue(Cue.seal);
      final capsule = await CapsuleRepository.create(
        coupleId: couple.id,
        title: _title.text.trim(),
        mode: _mode,
        unlockDate: _needsDate ? _date : null,
      );
      if (mounted) {
        // Straight into filling it.
        context.pushReplacement('/app/capsule/view', extra: capsule);
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = friendlyAuthError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('New capsule'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Name your capsule',
                style: Theme.of(context).textTheme.displaySmall,),
            const SizedBox(height: 8),
            const Text(
              'Something to look forward to — "Until Lisbon", "Our reunion".',
              style: TextStyle(color: MilesColors.taupe, height: 1.5),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _title,
              style: const TextStyle(color: MilesColors.cream50),
              decoration: const InputDecoration(hintText: 'Capsule name'),
            ),
            const SizedBox(height: 32),
            Text('How should it open?',
                style: Theme.of(context).textTheme.titleLarge,),
            const SizedBox(height: 12),
            _ModeTile(
              emoji: '🧲',
              title: "When we're together",
              blurb: "Unlocks when you're in the same place again.",
              selected: _mode == CapsuleUnlockMode.proximity,
              onTap: () => setState(() => _mode = CapsuleUnlockMode.proximity),
            ),
            _ModeTile(
              emoji: '📅',
              title: 'On a date',
              blurb: 'Unlocks on a day you choose.',
              selected: _mode == CapsuleUnlockMode.date,
              onTap: () => setState(() => _mode = CapsuleUnlockMode.date),
            ),
            _ModeTile(
              emoji: '✨',
              title: 'Both',
              blurb: 'Together AND on the day.',
              selected: _mode == CapsuleUnlockMode.both,
              onTap: () => setState(() => _mode = CapsuleUnlockMode.both),
            ),
            if (_needsDate) ...[
              const SizedBox(height: 16),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: MilesColors.surface2,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.event, color: MilesColors.gilt),
                      const SizedBox(width: 12),
                      Text(
                        _date == null
                            ? 'Pick a date & time'
                            : DateFormat('EEE, MMM d, y · h:mm a').format(_date!),
                        style: TextStyle(
                          color: _date == null
                              ? MilesColors.faint
                              : MilesColors.cream50,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: MilesColors.blush)),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),)
                  : const Text('Seal & start filling'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.emoji,
    required this.title,
    required this.blurb,
    required this.selected,
    required this.onTap,
  });
  final String emoji;
  final String title;
  final String blurb;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected
                ? MilesColors.tint(MilesColors.ember, 0.12)
                : MilesColors.surface1,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? MilesColors.ember
                  : MilesColors.gilt.withValues(alpha: 0.12),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: MilesColors.cream50,
                            fontWeight: FontWeight.w600,),),
                    const SizedBox(height: 2),
                    Text(blurb,
                        style: const TextStyle(
                            color: MilesColors.taupe, fontSize: 12.5,),),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle, color: MilesColors.ember),
            ],
          ),
        ),
      ),
    );
  }
}
