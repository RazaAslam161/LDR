/// Central place for app-wide constants and helpers.
class MilesConfig {
  MilesConfig._();

  /// Loaded from .env at runtime via flutter_dotenv.
  static const supabaseUrlKey = 'NEXT_PUBLIC_SUPABASE_URL';
  static const supabaseAnonKeyKey = 'NEXT_PUBLIC_SUPABASE_ANON_KEY';

  /// Google Maps Platform key for the photorealistic 3D map (Map Tiles API +
  /// Maps JavaScript API). Set in .env as GOOGLE_MAPS_3D_KEY.
  static const mapsApiKeyKey = 'GOOGLE_MAPS_3D_KEY';
}

/// Default breathing pattern used by Breath Sync (4-7-8 relaxation breath).
class BreathPattern {
  BreathPattern._();

  static const inhaleSeconds = 4;
  static const holdSeconds = 7;
  static const exhaleSeconds = 8;
  static const totalCycleSeconds = inhaleSeconds + holdSeconds + exhaleSeconds;
}

/// Common timezone picker (kept short; we'll expand later).
const List<String> commonTimezones = [
  'America/Los_Angeles',
  'America/Denver',
  'America/Chicago',
  'America/New_York',
  'America/Sao_Paulo',
  'Europe/London',
  'Europe/Berlin',
  'Europe/Paris',
  'Europe/Istanbul',
  'Asia/Dubai',
  'Asia/Karachi',
  'Asia/Kolkata',
  'Asia/Dhaka',
  'Asia/Singapore',
  'Asia/Tokyo',
  'Australia/Sydney',
  'Pacific/Auckland',
];
