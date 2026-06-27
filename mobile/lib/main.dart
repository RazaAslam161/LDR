import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/ads/ad_service.dart';
import 'package:miles/core/config.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/router.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/permissions_bootstrap.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/features/call/call_pill.dart';
import 'package:miles/features/fake_news/fake_news_screen.dart';
import 'package:miles/firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Global error nets: surface the FULL exception + stack (Issue 3) and keep
  //    one bad async error from blanking a whole feature. Permanent safety net.
  FlutterError.onError = (details) {
    debugPrint('FLUTTER ERROR: ${details.exception}\n${details.stack}');
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    debugPrint('PLATFORM ERROR: $error\n$stack');
    return true;
  };

  await dotenv.load();
  // An empty url/key would FormatException on every Supabase request — log
  // (masked) and fail fast with a clear message rather than a cryptic crash.
  final envUrl = dotenv.maybeGet(MilesConfig.supabaseUrlKey) ?? '';
  final envKey = dotenv.maybeGet(MilesConfig.supabaseAnonKeyKey) ?? '';
  debugPrint(
      'ENV CHECK → url len: ${envUrl.length}, key len: ${envKey.length}');
  if (envUrl.isEmpty || envKey.isEmpty) {
    throw StateError('Supabase env missing: ensure mobile/.env has '
        '${MilesConfig.supabaseUrlKey} and ${MilesConfig.supabaseAnonKeyKey}.');
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Must be registered before runApp; runs in its own isolate when a push
  // arrives while the app is backgrounded or terminated.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  TzHelper.ensureInit();
  await SupabaseService.init();
  initRealtimeAutoResume(); // rejoin channels whenever the socket (re)connects
  await AdService.init();
  await FcmService.init();
  // Lets the call's background foreground-service talk to the UI isolate.
  FlutterForegroundTask.initCommunicationPort();
  debugPrint('STARTUP OK → booting app');

  runApp(const ProviderScope(child: MilesApp()));
}

class MilesApp extends ConsumerStatefulWidget {
  const MilesApp({super.key});

  /// Whether the real Tethered app is shown (true) or the fake News cover
  /// (false). Reset to false on every background so returning always requires
  /// re-authentication; only FakeNewsScreen sets it true after the biometric +
  /// intro-video reveal. Static so the cover screen and the lifecycle handler
  /// share one source of truth.
  static final ValueNotifier<bool> showRealApp = ValueNotifier<bool>(false);

  /// True only while the biometric prompt is on screen. The prompt itself makes
  /// the app `inactive`; this guards that transition from resetting
  /// [showRealApp] and cancelling the unlock mid-auth.
  static bool authInProgress = false;

  @override
  ConsumerState<MilesApp> createState() => _MilesAppState();
}

class _MilesAppState extends ConsumerState<MilesApp>
    with WidgetsBindingObserver {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // First launch (any device): ask for all permissions at once.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => PermissionsBootstrap.requestAllOnce());
    // If the user enabled the biometric app-lock, raise it on launch. The
    // LockScreen auto-prompts biometrics when it appears.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => AppLock.lockIfEnabled());
    _initDeepLinks();
    _startHeartbeat(); // app launches foregrounded
  }

  /// Foreground presence heartbeat: re-stamps app_last_active_at every 30s (via
  /// setOnline(true)) so the 45s freshness window reads the partner as honestly
  /// online while the app is foregrounded — not just on the moment of a tap.
  /// Foreground-only + best-effort (battery reasonable; a single tiny upsert).
  void _startHeartbeat() {
    _heartbeat?.cancel();
    void beat() {
      final c = ref.read(currentCoupleProvider);
      if (c != null) PresenceService.setOnline(c.id, online: true);
    }

    beat(); // immediate beat so we read online without waiting a cycle
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => beat());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // SECURITY (cover layer): drop back to the News screen the instant the app
    // leaves the foreground, so returning ALWAYS requires re-authentication.
    // NEVER set it true here — only the entry flow does, after biometric +
    // intro video. This must run before the AppLock/presence logic below.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        MilesApp.showRealApp.value = false;
      case AppLifecycleState.inactive:
        // The biometric prompt itself makes the app inactive — don't reset the
        // cover mid-auth or it would cancel the unlock.
        if (!MilesApp.authInProgress) MilesApp.showRealApp.value = false;
      case AppLifecycleState.resumed:
        break;
    }

    // Biometric app-lock: raise on background, prompt to unlock on resume — but
    // only while the REAL app is visible, never unsolicited over the News cover.
    if (state == AppLifecycleState.paused) {
      AppLock.lockIfEnabled();
    } else if (state == AppLifecycleState.resumed) {
      if (MilesApp.showRealApp.value && AppLock.locked.value) {
        AppLock.authenticate(); // re-prompt on return
      }
      // Refresh the FCM token every resume — self-heals a token the notify
      // functions nulled server-side (UNREGISTERED), restoring pushes.
      FcmService.registerToken();
    }
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    // Only resumed => online + beating. paused/detached => stop + offline hint
    // (best-effort; the freshness TTL is the real safety net on a hard kill).
    // NB: `inactive` is transient (shade / app-switcher) — leave presence as-is
    // so it doesn't flicker offline.
    if (state == AppLifecycleState.resumed) {
      _startHeartbeat();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopHeartbeat();
      // Write offline hint + clear chat presence (kills phantom "is here"
      // avatar and stale seen/delivered ticks on the partner's screen).
      // Best-effort; the freshness TTL is the real safety net on a hard kill.
      PresenceService.setOnline(couple.id, online: false);
      PresenceService.clearChatPresence(couple.id);
    }
  }

  Future<void> _initDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handleLink(initial);
    } catch (_) {}
    _sub = _appLinks.uriLinkStream.listen(_handleLink, onError: (_) {});
  }

  /// Handles tethered://join?code=ABCDEF — stash the code and send the user to
  /// the pairing screen (the router gates auth/onboarding from there).
  void _handleLink(Uri uri) {
    if (uri.scheme != 'tethered' || uri.host != 'join') return;
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) return;
    ref.read(pendingInviteCodeProvider.notifier).state = code.toUpperCase();
    ref.read(routerProvider).go('/couple');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopHeartbeat();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The cover/real swap is driven by the static showRealApp notifier so the
    // lifecycle handler (and FakeNewsScreen) can flip it without setState.
    return ValueListenableBuilder<bool>(
      valueListenable: MilesApp.showRealApp,
      builder: (context, isReal, _) {
        // Cover layer: a convincing "News" app shown on cold start and the
        // instant the app backgrounds. Only a secret trigger + biometric pass +
        // the intro video swaps in the real app. Its clean light theme shares
        // nothing with Tethered's Emberlight dark theme.
        if (!isReal) {
          return MaterialApp(
            title: 'News',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.light,
              scaffoldBackgroundColor: Colors.white,
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF1A73E8),
                brightness: Brightness.light,
              ),
              useMaterial3: true,
            ),
            home: FakeNewsScreen(
              onAuthenticated: () => MilesApp.showRealApp.value = true,
            ),
          );
        }

        final router = ref.watch(routerProvider);
        return MaterialApp.router(
          // Keep the disguised name in the task switcher too.
          title: 'News',
          debugShowCheckedModeBanner: false,
          theme: milesDarkTheme(),
          routerConfig: router,
          builder: (context, child) => Stack(
            children: [
              // Always-present candle-glow backdrop so glassmorphism has
              // something to blur against on every screen.
              const EmberBackground(child: SizedBox.shrink()),
              // The routed screen, transparent so the glow shows through.
              child ?? const SizedBox.shrink(),
              // Return-to-call pill while a call is minimised.
              const CallPill(),
              // Biometric lock sits on top of everything.
              ValueListenableBuilder<bool>(
                valueListenable: AppLock.locked,
                builder: (context, locked, _) =>
                    locked ? const LockScreen() : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
    );
  }
}
