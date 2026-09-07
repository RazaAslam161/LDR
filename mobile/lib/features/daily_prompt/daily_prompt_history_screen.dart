import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/daily_prompt/daily_prompt_repository.dart';

/// Every question the two of them have been asked, and what they said.
///
/// The rows were always in the table; nothing read them. Yesterday's question
/// and both answers to it left the app the moment the date rolled over — which
/// on the one surface in this app designed to accumulate is the whole point of
/// it, gone.
class DailyPromptHistoryScreen extends ConsumerStatefulWidget {
  const DailyPromptHistoryScreen({super.key});

  @override
  ConsumerState<DailyPromptHistoryScreen> createState() =>
      _DailyPromptHistoryScreenState();
}

class _DailyPromptHistoryScreenState
    extends ConsumerState<DailyPromptHistoryScreen> {
  final _scroll = ScrollController();
  final _prompts = <DailyPrompt>[];
  Map<String, List<PromptResponse>> _responses = const {};

  bool _loading = true;
  bool _loadingMore = false;
  bool _more = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 400) unawaited(_load());
  }

  Future<void> _load() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null || _loadingMore || (!_more && _prompts.isNotEmpty)) {
      if (couple == null && mounted) setState(() => _loading = false);
      return;
    }
    _loadingMore = true;
    try {
      final page = await DailyPromptRepository.history(
        couple.id,
        before: _prompts.isEmpty
            ? null
            : _dateKey(_prompts.last.scheduledDate),
      );
      // One round trip for the whole page. Per prompt would be thirty selects
      // behind one screen.
      final answers = await DailyPromptRepository.responsesForMany(
        [for (final p in page) p.id],
      );
      if (!mounted) return;
      final have = {for (final p in _prompts) p.id};
      setState(() {
        _more = page.length >= DailyPromptRepository.historyPageSize;
        _prompts.addAll(page.where((p) => have.add(p.id)));
        _responses = {..._responses, ...answers};
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
          // A page that threw is not the end of the history, and it is not
          // more of it either. Left true, the footer spun forever over a
          // failure nothing on screen ever mentioned; the scroll listener
          // would also re-fire it at every frame.
          _more = false;
        });
      }
    } finally {
      _loadingMore = false;
    }
  }

  /// The cursor for the next page, from a `date` column.
  ///
  /// NOT `toUtc()`. `scheduled_date` is a bare `date`; PostgREST hands it over
  /// with no zone, so `parseDate` makes a LOCAL midnight — and converting that
  /// to UTC in any zone east of Greenwich moves it to the previous evening and
  /// the key goes back a day. On the owner's own machine (UTC+5) a page ending
  /// on the 6th asked for everything before the 5th, silently skipping a day
  /// of questions at every page boundary.
  static String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final uid = SupabaseService.currentUserId;
    final partnerName =
        ref.watch(sessionProvider).partner?.displayName ?? 'your partner';
    return Scaffold(
      backgroundColor: MilesColors.night,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Past questions'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _prompts.isEmpty
              ? _Retry(onRetry: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  unawaited(_load());
                },)
              : _prompts.isEmpty
                  ? const Center(
                      child: Text(
                        'No questions yet — the first one arrives today.',
                        style: TextStyle(color: MilesColors.taupe),
                      ),
                    )
                  : ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: _prompts.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, i) {
                        if (i == _prompts.length) {
                          if (_error != null) {
                            // The pages already on screen are still correct;
                            // only the next one failed.
                            return Center(
                              child: TextButton(
                                onPressed: () {
                                  setState(() {
                                    _error = null;
                                    _more = true;
                                  });
                                  unawaited(_load());
                                },
                                child: const Text(
                                  'Could not load older questions — try again',
                                  style: TextStyle(
                                      color: MilesColors.taupe, fontSize: 13,),
                                ),
                              ),
                            );
                          }
                          return _more
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Center(
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: MilesColors.taupe,
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox(height: 24);
                        }
                        final p = _prompts[i];
                        return _PromptCard(
                          prompt: p,
                          responses: _responses[p.id] ?? const [],
                          uid: uid,
                          partnerName: partnerName,
                        );
                      },
                    ),
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Could not load your questions.',
                style: TextStyle(color: MilesColors.cream50),),
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
}

/// One past question and what each of them said to it.
class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.prompt,
    required this.responses,
    required this.uid,
    required this.partnerName,
  });

  final DailyPrompt prompt;
  final List<PromptResponse> responses;
  final String? uid;
  final String partnerName;

  static final _date = DateFormat('EEEE, d MMMM');

  @override
  Widget build(BuildContext context) {
    final mine =
        responses.where((r) => r.userId == uid).firstOrNull?.responseText;
    final theirs =
        responses.where((r) => r.userId != uid).firstOrNull?.responseText;
    // The SAME reveal rule the day's own card keeps: both answers appear
    // together or neither does. A history screen that showed the partner's
    // answer to a question you never answered would be a way to read them
    // without ever writing anything back.
    final both = mine != null && theirs != null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _date.format(prompt.scheduledDate.toLocal()),
            style: const TextStyle(color: MilesColors.faint, fontSize: 11),
          ),
          const SizedBox(height: 6),
          Text(
            prompt.promptText,
            style: const TextStyle(
                color: MilesColors.cream50,
                fontSize: 15,
                fontWeight: FontWeight.w600,),
          ),
          const SizedBox(height: 10),
          if (both) ...[
            _Answer(who: 'You', text: mine),
            const SizedBox(height: 8),
            _Answer(who: partnerName, text: theirs),
          ] else
            Text(
              mine == null
                  ? 'You never answered this one.'
                  : '$partnerName never answered, so both answers stayed '
                      'hidden.',
              style: const TextStyle(
                  color: MilesColors.taupe,
                  fontSize: 13,
                  fontStyle: FontStyle.italic,),
            ),
        ],
      ),
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer({required this.who, required this.text});
  final String who;
  final String text;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(who,
              style: const TextStyle(
                  color: MilesColors.gilt,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,),),
          const SizedBox(height: 2),
          Text(text,
              style: const TextStyle(
                  color: MilesColors.cream50, fontSize: 14, height: 1.35,),),
        ],
      );
}
