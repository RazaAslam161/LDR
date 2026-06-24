import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:miles/core/config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Singleton Supabase client. Call [init] once at app startup.
class SupabaseService {
  SupabaseService._();

  static late final SupabaseClient client;

  static Future<void> init() async {
    await Supabase.initialize(
      url: dotenv.get(MilesConfig.supabaseUrlKey),
      anonKey: dotenv.get(MilesConfig.supabaseAnonKeyKey),
      debug: false,
    );
    client = Supabase.instance.client;
  }

  /// Current authed user id, or null.
  static String? get currentUserId => client.auth.currentUser?.id;

  /// Stream of auth state changes — used by the session provider.
  static Stream<AuthState> get authChanges => client.auth.onAuthStateChange;
}
