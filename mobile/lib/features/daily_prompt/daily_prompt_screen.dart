import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/models.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/features/daily_prompt/daily_prompt_repository.dart';

/// Today's question + your answer. Both partners' answers are revealed
/// only after both have responded.
class DailyPromptScreen extends ConsumerStatefulWidget {
  const DailyPromptScreen({super.key});

  @override
  ConsumerState<DailyPromptScreen> createState() => _DailyPromptScreenState();
}

class _DailyPromptScreenState extends ConsumerState<DailyPromptScreen> {
  DailyPrompt? _prompt;
  List<PromptResponse> _responses = const [];
  String? _error;
  bool _loading = true;
  bool _saving = false;

  final _answer = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void dispose() {
    _answer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider);
    final couple = session.couple;
    if (couple == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prompt = await DailyPromptRepository.ensureToday(
        coupleId: couple.id,
        localToday: DateTime.now(),
      );
      final responses = await DailyPromptRepository.responsesFor(prompt.id);

      final myUid = session.profile?.id;
      final mine = responses.firstWhere(
        (r) => r.userId == myUid,
        orElse: () => PromptResponse.empty,
      );
      // Pre-fill the textarea if the user already has a saved answer.
      if (_answer.text.isEmpty && mine.responseText != null) {
        _answer.text = mine.responseText!;
      }

      if (!mounted) return;
      setState(() {
        _prompt = prompt;
        _responses = responses;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    final prompt = _prompt;
    final text = _answer.text.trim();
    if (prompt == null || text.isEmpty) return;

    setState(() => _saving = true);
    try {
      await DailyPromptRepository.upsertMyResponse(
        promptId: prompt.id,
        responseText: text,
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final me = session.profile;
    final partner = session.partner;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily Question'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: _body(myUid: me?.id, partner: partner),
      ),
    );
  }

  Widget _body({String? myUid, Profile? partner}) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_error != null) {
      return _CenteredMessage(
        icon: Icons.cloud_off,
        message: _error!,
        action: _load,
        actionLabel: 'Retry',
      );
    }
    final prompt = _prompt;
    if (prompt == null) {
      return const _CenteredMessage(
        icon: Icons.question_answer,
        message: 'No prompt for today yet — check back in a moment.',
      );
    }

    final mine = _responses.firstWhere(
      (r) => r.userId == myUid,
      orElse: () => PromptResponse.empty,
    );
    final partnerResp = _responses.firstWhere(
      (r) => r.userId == partner?.id,
      orElse: () => PromptResponse.empty,
    );
    final bothAnswered =
        mine.responseText != null && partnerResp.responseText != null;

    return RefreshIndicator(
      color: const Color(0xFFEF6F58),
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        children: [
          const Text(
            'TODAY',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 3,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF4937E),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            prompt.promptText,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  color: const Color(0xFFFBF8F4),
                  height: 1.25,
                ),
          ),
          const SizedBox(height: 32),

          // ─── Answer box ─────────────────────────────────────────
          TextField(
            controller: _answer,
            minLines: 4,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'Your answer…',
              suffixIcon: _answer.text.trim().isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.check_circle),
                      color: const Color(0xFFEF6F58),
                      onPressed: _saving ? null : _submit,
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          if (mine.responseText != null)
            const Text(
              'Your answer is saved. You can keep editing.',
              style: TextStyle(fontSize: 11, color: Color(0x80F5EFE6)),
            ),
          const SizedBox(height: 28),

          // ─── Reveal ─────────────────────────────────────────────
          _RevealSection(
            myName: ref.read(sessionProvider).profile?.displayName ?? 'You',
            partnerName: partner?.displayName ?? 'Your partner',
            mine: mine.responseText,
            partner: partnerResp.responseText,
            bothAnswered: bothAnswered,
            partnerPending: partnerResp.responseText == null,
          ),
        ],
      ),
    );
  }
}

/// "Both have answered" reveal card.
class _RevealSection extends StatelessWidget {
  const _RevealSection({
    required this.myName,
    required this.partnerName,
    required this.mine,
    required this.partner,
    required this.bothAnswered,
    required this.partnerPending,
  });
  final String myName;
  final String partnerName;
  final String? mine;
  final String? partner;
  final bool bothAnswered;
  final bool partnerPending;

  @override
  Widget build(BuildContext context) {
    if (!bothAnswered) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF141B26).withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            Icon(
              partnerPending ? Icons.hourglass_top : Icons.lock_outline,
              color: const Color(0xFFF4937E),
            ),
            const SizedBox(height: 12),
            Text(
              partnerPending
                  ? "$partnerName hasn't answered yet. You'll see both answers here the moment they do."
                  : 'Both answers reveal together.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFBF8F4),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AnswerCard(name: partnerName, text: partner ?? ''),
        const SizedBox(height: 12),
        _AnswerCard(name: myName, text: mine ?? '', accent: true),
      ],
    );
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.name, required this.text, this.accent = false});
  final String name;
  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF141B26).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: accent
            ? Border.all(
                color: const Color(0xFFEF6F58).withValues(alpha: 0.3),
              )
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 2,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF4937E),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFFFBF8F4),
              fontSize: 15,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({
    required this.icon,
    required this.message,
    this.action,
    this.actionLabel,
  });
  final IconData icon;
  final String message;
  final VoidCallback? action;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: const Color(0x80F5EFE6)),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFBF8F4),
                fontSize: 15,
                height: 1.5,
              ),
            ),
            if (action != null && actionLabel != null) ...[
              const SizedBox(height: 24),
              FilledButton(onPressed: action, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
