import 'package:flutter/material.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/features/rituals/ritual_repository.dart';

/// Modal sheet for creating a new ritual.
///
/// The delivery time is picked in *the user's* local timezone; the value
/// is stored as UTC and the listing screen re-renders it as
/// "HH:MM their time" for the partner.
class CreateRitualSheet extends StatefulWidget {
  const CreateRitualSheet({required this.coupleId, super.key});
  final String coupleId;

  @override
  State<CreateRitualSheet> createState() => _CreateRitualSheetState();
}

class _CreateRitualSheetState extends State<CreateRitualSheet> {
  RitualType _type = RitualType.goodnight;
  TimeOfDay _time = const TimeOfDay(hour: 22, minute: 0);
  final _message = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Write a small message first.');
      return;
    }

    final now = DateTime.now();
    final deliverAt = DateTime(
      now.year,
      now.month,
      now.day,
      _time.hour,
      _time.minute,
    );

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await RitualRepository.create(
        coupleId: widget.coupleId,
        type: _type,
        message: text,
        deliverAt: deliverAt,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0x33F5EFE6),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'New ritual',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: const Color(0xFFFBF8F4),
                  ),
            ),
            const SizedBox(height: 24),

            // ─── Type ──────────────────────────────────────────────
            const _Label('TYPE'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final t in RitualType.values)
                  ChoiceChip(
                    label: Text(_typeLabel(t)),
                    selected: _type == t,
                    selectedColor: const Color(0xFFEF6F58),
                    labelStyle: TextStyle(
                      color: _type == t
                          ? const Color(0xFF0B0F16)
                          : const Color(0xFFFBF8F4),
                    ),
                    onSelected: (_) => setState(() => _type = t),
                  ),
              ],
            ),
            const SizedBox(height: 20),

            // ─── Time ──────────────────────────────────────────────
            const _Label('DELIVERS AT (YOUR TIME)'),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _time,
                );
                if (picked != null) setState(() => _time = picked);
              },
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: const Color(0x0dFFFFFF),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0x33F5EFE6).withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.access_time,
                      color: Color(0xFFF4937E),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _formatTimeOfDay(_time),
                      style: const TextStyle(color: Color(0xFFFBF8F4)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ─── Message ───────────────────────────────────────────
            const _Label('MESSAGE'),
            const SizedBox(height: 8),
            TextField(
              controller: _message,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: "A line they'll see when it lands…",
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This is a v1 preview — scheduling lands soon. '
              'Your message will show in their list at this time.',
              style: TextStyle(fontSize: 11, color: Color(0x80F5EFE6)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFEF6F58)),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _loading ? null : _save,
              child: _loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save ritual'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimeOfDay(TimeOfDay t) {
    final period = t.hour >= 12 ? 'PM' : 'AM';
    final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$hour12:${t.minute.toString().padLeft(2, '0')} $period';
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 2,
        fontWeight: FontWeight.w600,
        color: Color(0xFFF4937E),
      ),
    );
  }
}

String _typeLabel(RitualType t) {
  switch (t) {
    case RitualType.goodnight:
      return 'Goodnight';
    case RitualType.goodmorning:
      return 'Good morning';
    case RitualType.weeklyHighlow:
      return 'Highs & lows';
    case RitualType.custom:
      return 'Custom';
  }
}
