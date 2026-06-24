import 'package:flutter/material.dart';
import 'package:miles/core/supabase_repository.dart';

/// Modal sheet for setting the next visit date + optional location.
class SetVisitSheet extends StatefulWidget {
  const SetVisitSheet({required this.coupleId, super.key});
  final String coupleId;

  @override
  State<SetVisitSheet> createState() => _SetVisitSheetState();
}

class _SetVisitSheetState extends State<SetVisitSheet> {
  DateTime _date = DateTime.now().add(const Duration(days: 30));
  final _location = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _location.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await SupabaseRepository.setNextVisit(
        coupleId: widget.coupleId,
        startDate: _date,
        location: _location.text.trim().isEmpty ? null : _location.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
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
            'Set your next visit',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: const Color(0xFFFBF8F4),
                ),
          ),
          const SizedBox(height: 24),
          CalendarDatePicker(
            initialDate: _date,
            firstDate: DateTime.now(),
            lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
            onDateChanged: (d) => setState(() => _date = d),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _location,
            decoration: const InputDecoration(
              hintText: 'Where? Their city, your city, somewhere new…',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFEF6F58))),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _loading ? null : _save,
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start the countdown'),
          ),
        ],
      ),
    );
  }
}
