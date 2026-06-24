/// Defensive JSON parsing helpers.
///
/// Supabase can return numbers as strings, nulls where you expect values, and
/// occasionally unexpected types. NEVER cast raw inside a `fromJson()` — a
/// single malformed row would crash the whole list with a `FormatException`.
/// Route every field through these instead.
class JsonUtils {
  JsonUtils._();

  /// Parse a date, falling back to [fallback] (or `now`) on null/garbage.
  static DateTime parseDate(dynamic value, {DateTime? fallback}) {
    if (value is DateTime) return value;
    if (value != null) {
      final parsed = DateTime.tryParse(value.toString());
      if (parsed != null) return parsed;
    }
    return fallback ?? DateTime.now();
  }

  /// Parse a nullable date — null/garbage → null.
  static DateTime? parseDateOrNull(dynamic value) {
    if (value is DateTime) return value;
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static int parseInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double parseDouble(dynamic value, {double fallback = 0.0}) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static String parseString(dynamic value, {String fallback = ''}) {
    if (value == null) return fallback;
    return value.toString();
  }

  static String? parseStringOrNull(dynamic value) => value?.toString();

  static bool parseBool(dynamic value, {bool fallback = false}) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final s = value?.toString().toLowerCase();
    if (s == 'true' || s == 't' || s == '1') return true;
    if (s == 'false' || s == 'f' || s == '0') return false;
    return fallback;
  }

  /// Parse a nested object, tolerating a plain `Map` (not strictly typed) or null.
  static T? parseObject<T>(
    dynamic value,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (value is Map<String, dynamic>) return fromJson(value);
    if (value is Map) return fromJson(Map<String, dynamic>.from(value));
    return null;
  }

  /// Parse a list of objects, skipping any element that isn't a map.
  static List<T> parseList<T>(
    dynamic value,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (value is! List) return <T>[];
    return value
        .whereType<Map>()
        .map((e) => fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Normalise any value to a `Map<String,dynamic>` (e.g. realtime payloads).
  static Map<String, dynamic> asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }
}
