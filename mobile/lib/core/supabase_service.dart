import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/config.dart';
import 'package:miles/core/net/timeout_http_client.dart';
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
      // Every request gets a ceiling. Without this a stalled socket on a poor
      // connection leaves whichever screen is awaiting it spinning forever,
      // with no error to show and nothing for the user to do.
      httpClient: TimeoutHttpClient(http.Client()),
    );
    client = Supabase.instance.client;
  }

  /// Current authed user id, or null.
  static String? get currentUserId => client.auth.currentUser?.id;

  /// Stream of auth state changes — used by the session provider.
  static Stream<AuthState> get authChanges => client.auth.onAuthStateChange;
}
