import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/config.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_repository.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/auth/widgets/alert_banner.dart';
import 'package:miles/features/auth/widgets/labeled_field.dart';

/// Step 1 of onboarding: tell us about you (name, timezone, date of birth).
/// On success we refresh the session and move to the couple-linking step.
class WelcomePage extends ConsumerStatefulWidget {
  const WelcomePage({super.key});

  @override
  ConsumerState<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends ConsumerState<WelcomePage> {
  final _name = TextEditingController();
  String _timezone = '';
  DateTime? _birthDate;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Try to detect the device timezone; fall back to the first known one.
    try {
      final detected = DateTime.now().timeZoneName;
      _timezone = commonTimezones.contains(detected)
          ? detected
          : commonTimezones.first;
    } catch (_) {
      _timezone = commonTimezones.first;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Returns the user's age in whole years, or null if no DOB picked yet.
  int? get _age {
    if (_birthDate == null) return null;
    final today = DateTime.now();
    var age = today.year - _birthDate!.year;
    if (today.month < _birthDate!.month ||
        (today.month == _birthDate!.month && today.day < _birthDate!.day)) {
      age--;
    }
    return age;
  }

  bool get _isUnderage {
    final age = _age;
    return age != null && age < 18;
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 25),
      firstDate: DateTime(1920),
      lastDate: DateTime(now.year - 13), // don't even tempt fate
      helpText: 'When were you born?',
    );
    if (picked != null) {
      setState(() => _birthDate = picked);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final displayName = _name.text.trim();
      if (displayName.isEmpty) {
        throw StateError('Please tell us your name.');
      }
      if (_birthDate == null) {
        throw StateError('Please enter your date of birth.');
      }
      if (_isUnderage) {
        throw StateError('You must be 18 or older to use Miles.');
      }

      // YYYY-MM-DD for the Postgres date column.
      final birthDateStr =
          '${_birthDate!.year.toString().padLeft(4, '0')}-'
          '${_birthDate!.month.toString().padLeft(2, '0')}-'
          '${_birthDate!.day.toString().padLeft(2, '0')}';

      await SupabaseRepository.upsertProfile(
        displayName: displayName,
        timezone: _timezone,
        birthDate: birthDateStr,
      );

      // Refresh session so the router sees an onboarded profile, then move to
      // the couple step (create or join).
      await ref.read(sessionProvider.notifier).loadProfile();
      if (mounted) {
        context.go('/couple');
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = friendlyAuthError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 64),
              Text(
                'A little about you',
                style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      color: const Color(0xFFFBF8F4),
                    ),
              ),
              const SizedBox(height: 8),
              const Text(
                "We'll use this to set up your space.",
                style: TextStyle(color: Color(0x99F5EFE6)),
              ),
              const SizedBox(height: 32),
              LabeledField(
                label: 'Your name',
                child: TextField(
                  controller: _name,
                  // Her real name must not end up in the keyboard's dictionary
                  // and resurface as a suggestion in some other app.
                  enableIMEPersonalizedLearning: false,
                  decoration: const InputDecoration(
                    hintText: 'What should we call you?',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Your timezone',
                child: DropdownButtonFormField<String>(
                  initialValue: _timezone,
                  decoration: const InputDecoration(),
                  items: commonTimezones
                      .map(
                        (tz) => DropdownMenuItem(
                          value: tz,
                          child: Text(tz.replaceAll('_', ' ')),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _timezone = v ?? _timezone),
                ),
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Date of birth',
                child: InkWell(
                  onTap: _pickBirthDate,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      hintText: 'Required · must be 18+',
                    ),
                    child: Text(
                      _birthDate == null
                          ? 'Required · must be 18+'
                          : '${_birthDate!.day.toString().padLeft(2, '0')}/'
                              '${_birthDate!.month.toString().padLeft(2, '0')}/'
                              '${_birthDate!.year}',
                      style: TextStyle(
                        color: _birthDate == null
                            ? const Color(0x4dF5EFE6)
                            : const Color(0xFFFBF8F4),
                      ),
                    ),
                  ),
                ),
              ),
              if (_isUnderage) ...[
                const SizedBox(height: 16),
                const AlertBanner(
                  message: 'You must be 18 or older to use Miles.',
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                AlertBanner(message: _error!),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: (_loading || _isUnderage) ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Continue'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Miles is for adults only. Your date of birth is stored on '
                'your profile and never shared.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Color(0x66F5EFE6)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
