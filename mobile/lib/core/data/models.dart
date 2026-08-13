/// Strongly-typed models that map to the Postgres schema in supabase/schema.sql.
///
/// Field names are camelCase in Dart and snake_case in the DB — converters
/// live in [SupabaseRepository] so these stay clean.
library;

import 'package:miles/core/data/supabase_repository.dart'
    show SupabaseRepository;
import 'package:miles/core/utils/json_utils.dart';

enum PresenceStatus { asleep, awake, work, free, busy }

enum RitualType { goodnight, goodmorning, weeklyHighlow, custom }

class Couple {
  Couple({
    required this.id,
    required this.inviteCode,
    required this.createdAt,
    this.name,
    this.primaryTz,
    this.stripeCustomerId,
    this.modestMode = false,
    this.anniversaryDate,
  });

  factory Couple.fromJson(Map<String, dynamic> json) {
    return Couple(
      id: JsonUtils.parseString(json['id']),
      inviteCode: JsonUtils.parseString(json['invite_code']),
      createdAt: JsonUtils.parseDate(json['created_at']),
      name: JsonUtils.parseStringOrNull(json['name']),
      primaryTz: JsonUtils.parseStringOrNull(json['primary_tz']),
      stripeCustomerId: JsonUtils.parseStringOrNull(json['stripe_customer_id']),
      modestMode: JsonUtils.parseBool(json['modest_mode']),
      anniversaryDate: JsonUtils.parseDateOrNull(json['anniversary_date']),
    );
  }

  final String id;
  final String inviteCode;
  final DateTime createdAt;
  final String? name;
  final String? primaryTz;
  final String? stripeCustomerId;
  final DateTime? anniversaryDate;

  /// When true, hides the entire intimacy module for both partners.
  /// Coupled-scoped because it affects both partners' experience.
  final bool modestMode;
}

class Profile {
  Profile({
    required this.id,
    required this.displayName,
    required this.timezone,
    required this.presenceStatus,
    required this.createdAt,
    this.coupleId,
    this.avatarUrl,
    this.wakeTime,
    this.sleepTime,
    this.birthDate,
    this.statusMessage,
    this.gender,
    this.genderSet = false,
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: JsonUtils.parseString(json['id']),
      coupleId: JsonUtils.parseStringOrNull(json['couple_id']),
      displayName: JsonUtils.parseString(json['display_name']),
      avatarUrl: JsonUtils.parseStringOrNull(json['avatar_url']),
      timezone: JsonUtils.parseString(json['timezone'], fallback: 'UTC'),
      wakeTime: JsonUtils.parseStringOrNull(json['wake_time']),
      sleepTime: JsonUtils.parseStringOrNull(json['sleep_time']),
      presenceStatus: _parsePresence(
        JsonUtils.parseString(json['presence_status'], fallback: 'free'),
      ),
      createdAt: JsonUtils.parseDate(json['created_at']),
      birthDate: JsonUtils.parseStringOrNull(json['birth_date']),
      statusMessage: JsonUtils.parseStringOrNull(json['status_message']),
      gender: JsonUtils.parseStringOrNull(json['gender']),
      genderSet: JsonUtils.parseBool(json['gender_set']),
    );
  }

  final String id;
  final String? coupleId;
  final String displayName;
  final String? avatarUrl;
  final String timezone;
  final String? wakeTime;
  final String? sleepTime;
  final PresenceStatus presenceStatus;
  final DateTime createdAt;

  /// ISO date (YYYY-MM-DD). Used for the 18+ age gate.
  final String? birthDate;

  /// Short status/bio line shown to the partner (max ~60 chars).
  final String? statusMessage;

  /// 'male' | 'female' — each user sets their own. Gates the cycle feature.
  final String? gender;
  final bool genderSet;
  bool get isFemale => gender == 'female';
  bool get isMale => gender == 'male';

  /// True once the user has completed profile onboarding. The signup trigger
  /// auto-creates a bare profile (no birth_date), so profile-existence alone
  /// can't tell us if onboarding is done — the DOB is the reliable signal.
  bool get isOnboarded => birthDate != null;

  /// Returns true if the user is 18 or older based on [birthDate].
  /// If [birthDate] is null, returns false (must verify before using app).
  bool get isAdult {
    if (birthDate == null) return false;
    try {
      final dob = DateTime.parse(birthDate!);
      final today = DateTime.now();
      var age = today.year - dob.year;
      if (today.month < dob.month ||
          (today.month == dob.month && today.day < dob.day)) {
        age--;
      }
      return age >= 18;
    } catch (_) {
      return false;
    }
  }

  static PresenceStatus _parsePresence(String raw) {
    return PresenceStatus.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => PresenceStatus.free,
    );
  }
}

class Visit {
  Visit({
    required this.id,
    required this.coupleId,
    required this.startDate,
    required this.isUpcoming,
    required this.createdAt,
    this.endDate,
    this.location,
    this.note,
  });

  factory Visit.fromJson(Map<String, dynamic> json) {
    return Visit(
      id: JsonUtils.parseString(json['id']),
      coupleId: JsonUtils.parseString(json['couple_id']),
      startDate: JsonUtils.parseDate(json['start_date']).toUtc(),
      endDate: JsonUtils.parseDateOrNull(json['end_date'])?.toUtc(),
      location: JsonUtils.parseStringOrNull(json['location']),
      note: JsonUtils.parseStringOrNull(json['note']),
      isUpcoming: JsonUtils.parseBool(json['is_upcoming'], fallback: true),
      createdAt: JsonUtils.parseDate(json['created_at']),
    );
  }

  final String id;
  final String coupleId;
  final DateTime startDate;
  final DateTime? endDate;
  final String? location;
  final String? note;
  final bool isUpcoming;
  final DateTime createdAt;

  /// Whole days of the visit if [endDate] is set, otherwise 0.
  int get durationDays {
    final end = endDate;
    if (end == null) return 0;
    final diff = end.difference(startDate);
    return diff.inDays < 0 ? 0 : diff.inDays;
  }
}

class Ritual {
  Ritual({
    required this.id,
    required this.coupleId,
    required this.type,
    required this.delivered,
    this.message,
    this.cron,
    this.deliverAt,
    this.deleteRequested = false,
    this.deleteRequestedBy,
  });

  factory Ritual.fromJson(Map<String, dynamic> json) {
    return Ritual(
      id: JsonUtils.parseString(json['id']),
      coupleId: JsonUtils.parseString(json['couple_id']),
      type: _parseRitualType(
        JsonUtils.parseString(json['type'], fallback: 'custom'),
      ),
      message: JsonUtils.parseStringOrNull(json['message']),
      cron: JsonUtils.parseStringOrNull(json['cron']),
      deliverAt: JsonUtils.parseDateOrNull(json['deliver_at'])?.toUtc(),
      delivered: JsonUtils.parseBool(json['delivered']),
      deleteRequested: (json['delete_requested'] as bool?) ?? false,
      deleteRequestedBy:
          JsonUtils.parseStringOrNull(json['delete_requested_by']),
    );
  }

  final String id;
  final String coupleId;
  final RitualType type;
  final String? message;
  final String? cron;
  final DateTime? deliverAt;
  final bool delivered;
  final bool deleteRequested;
  final String? deleteRequestedBy;
}

RitualType _parseRitualType(String raw) {
  return RitualType.values.firstWhere(
    (e) => e.name == raw,
    orElse: () => RitualType.custom,
  );
}

/// The serialized name used in the DB enum.
String ritualTypeToJson(RitualType type) {
  switch (type) {
    case RitualType.goodnight:
      return 'goodnight';
    case RitualType.goodmorning:
      return 'goodmorning';
    case RitualType.weeklyHighlow:
      return 'weekly_highlow';
    case RitualType.custom:
      return 'custom';
  }
}

class DailyPrompt {
  DailyPrompt({
    required this.id,
    required this.coupleId,
    required this.promptText,
    required this.scheduledDate,
  });

  factory DailyPrompt.fromJson(Map<String, dynamic> json) {
    return DailyPrompt(
      id: JsonUtils.parseString(json['id']),
      coupleId: JsonUtils.parseString(json['couple_id']),
      promptText: JsonUtils.parseString(json['prompt_text']),
      scheduledDate: JsonUtils.parseDate(json['scheduled_date']).toUtc(),
    );
  }

  final String id;
  final String coupleId;
  final String promptText;
  final DateTime scheduledDate;
}

class PromptResponse {
  PromptResponse({
    required this.id,
    required this.promptId,
    required this.userId,
    required this.respondedAt,
    this.responseText,
  });

  factory PromptResponse.fromJson(Map<String, dynamic> json) {
    return PromptResponse(
      id: JsonUtils.parseString(json['id']),
      promptId: JsonUtils.parseString(json['prompt_id']),
      userId: JsonUtils.parseString(json['user_id']),
      responseText: JsonUtils.parseStringOrNull(json['response_text']),
      respondedAt: JsonUtils.parseDate(json['responded_at']),
    );
  }

  final String id;
  final String promptId;
  final String userId;
  final String? responseText;
  final DateTime respondedAt;

  /// Sentinel used by `firstWhere(orElse: ...)`. `responseText == null`
  /// makes "did this user respond?" checks cheap and readable.
  static final PromptResponse empty = PromptResponse(
    id: '',
    promptId: '',
    userId: '',
    respondedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}
