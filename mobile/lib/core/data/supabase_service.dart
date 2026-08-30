import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:miles/core/app/config.dart';
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
      // The retry policy is stated rather than inherited. postgrest defaults to
      // retryCount 3 with no requestTimeout, and it retries on ANY exception —
      // including the ClientException TimeoutHttpClient throws — so a dead
      // socket cost four 30s attempts plus 1/2/4s of backoff on EVERY read in
      // the app, not just the slow one someone noticed. requestTimeout is the
      // half that matters: it aborts a stalled attempt instead of waiting out
      // the ceiling and then trying again. One retry still absorbs a transient
      // blip. Storage transfers are not governed here — they keep their own
      // much larger ceiling in TimeoutHttpClient.
      postgrestOptions: const PostgrestClientOptions(
        retryCount: 1,
        requestTimeout: Duration(seconds: 10),
      ),
    );
    client = Supabase.instance.client;
  }

  /// Current authed user id, or null.
  static String? get currentUserId => client.auth.currentUser?.id;

  /// Stream of auth state changes — used by the session provider.
  static Stream<AuthState> get authChanges => client.auth.onAuthStateChange;
}
