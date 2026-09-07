import 'package:miles/core/data/models.dart';
import 'package:miles/core/data/supabase_service.dart';

/// Curated pool of LDR-flavoured daily questions.
///
/// Selection is deterministic: `promptPool[dayOfYear % promptPool.length]`
/// so both partners see the same question on the same day without having
/// to coordinate.
const List<String> promptPool = <String>[
  "What's one small thing you wished you could share with me today?",
  'What does the version of us in the same city look like?',
  'What song did you play on repeat today, and why?',
  'When did you feel closest to me this week?',
  "What is something you are proud of that you haven't told me yet?",
  'What part of your day do you wish I had been there for?',
  "What's something tiny I do that you never want me to stop doing?",
  'If we could teleport for ten minutes right now, what would we do?',
  'What are you looking forward to most in our next visit?',
  "What's something difficult about the distance that you haven't said out loud?",
  "What's one thing you'd like us to start doing together while apart?",
  'What memory of us do you replay when you miss me most?',
  'What does your morning look like right now? Walk me through it.',
  "What is one thing you'd like to be braver about with me?",
  "What's a small way I can love you better this week?",
  'What part of yourself are you growing into lately?',
  "What's something you want to remember about this season of us?",
  'When distance ends, what is the first ordinary day you want to have together?',
  "What's a tiny dream you've had that you haven't told me about?",
  'What does "home" mean to you right now?',
];

/// Returns today's prompt string deterministically.
String promptForDay(DateTime date) {
  final dayOfYear = _dayOfYear(date);
  return promptPool[dayOfYear % promptPool.length];
}

int _dayOfYear(DateTime d) {
  final start = DateTime(d.year);
  return d.difference(start).inDays;
}

/// Wrapper around `daily_prompts` + `prompt_responses`.
///
/// One prompt per couple per day. The first partner to open the screen
/// creates the row; both partners' answers are revealed only once both
/// have responded.
class DailyPromptRepository {
  DailyPromptRepository._();

  static final _c = SupabaseService.client;

  /// Returns today's [DailyPrompt], creating it idempotently if needed.
  static Future<DailyPrompt> ensureToday({
    required String coupleId,
    required DateTime localToday,
  }) async {
    final today = DateTime(
      localToday.year,
      localToday.month,
      localToday.day,
    );

    // Look for an existing row first.
    final existing = await _c
        .from('daily_prompts')
        .select()
        .eq('couple_id', coupleId)
        .eq('scheduled_date', today.toIso8601String().substring(0, 10))
        .maybeSingle();
    if (existing != null) {
      return DailyPrompt.fromJson(existing);
    }

    final text = promptForDay(today);
    final inserted = await _c.from('daily_prompts').insert({
      'couple_id': coupleId,
      'prompt_text': text,
      'scheduled_date': today.toIso8601String().substring(0, 10),
    }).select().single();
    return DailyPrompt.fromJson(inserted);
  }

  /// One page of past prompts, newest first.
  static const historyPageSize = 30;

  /// Prompts BEFORE [before] (a `scheduled_date`), newest first.
  ///
  /// The question of the day was the only one that existed: yesterday's, and
  /// every answer either of them had written to it, was gone from the app the
  /// moment the date rolled over. The rows were always there — nothing ever
  /// read them.
  ///
  /// Cursored on `scheduled_date`, which is the unique key this table already
  /// has per couple, so no index is added for this.
  static Future<List<DailyPrompt>> history(
    String coupleId, {
    String? before,
  }) async {
    var q = _c.from('daily_prompts').select().eq('couple_id', coupleId);
    if (before != null) q = q.lt('scheduled_date', before);
    final res = await q
        .order('scheduled_date', ascending: false)
        .limit(historyPageSize);
    return (res as List)
        .map((e) => DailyPrompt.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Responses for a whole page of prompts, in ONE round trip.
  ///
  /// Asking per prompt would be thirty selects behind one screen, on a phone,
  /// on mobile data.
  static Future<Map<String, List<PromptResponse>>> responsesForMany(
    List<String> promptIds,
  ) async {
    if (promptIds.isEmpty) return const {};
    final res = await _c
        .from('prompt_responses')
        .select()
        .inFilter('prompt_id', promptIds);
    final out = <String, List<PromptResponse>>{};
    for (final e in res as List) {
      final r = PromptResponse.fromJson(e as Map<String, dynamic>);
      (out[r.promptId] ??= []).add(r);
    }
    return out;
  }

  /// All responses for [promptId].
  static Future<List<PromptResponse>> responsesFor(String promptId) async {
    final res = await _c
        .from('prompt_responses')
        .select()
        .eq('prompt_id', promptId);
    return (res as List)
        .map((e) => PromptResponse.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Upsert the current user's response for [promptId].
  static Future<void> upsertMyResponse({
    required String promptId,
    required String responseText,
  }) async {
    final uid = SupabaseService.currentUserId;
    if (uid == null) throw StateError('Not signed in');
    await _c.from('prompt_responses').upsert({
      'prompt_id': promptId,
      'user_id': uid,
      'response_text': responseText,
      'responded_at': DateTime.now().toUtc().toIso8601String(),
    // Without the natural key the conflict target is the surrogate id, which a
    // second answer never carries — so editing an answer inserted a duplicate
    // or failed the unique index instead of replacing the first.
    }, onConflict: 'prompt_id,user_id');
  }
}
