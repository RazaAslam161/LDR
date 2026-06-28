import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/ads/ad_service.dart';
import 'package:miles/core/config.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/realtime_resume.dart';
import 'package:miles/core/router.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/permissions_bootstrap.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/emergency_lock_service.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/core/widgets/stealth_overlay.dart';
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

  /// True while an in-app flow has intentionally handed focus to a system
  /// overlay — the gallery picker, the full-screen reaction camera, the
  /// media-source sheet, a permission dialog. These all bounce the app through
  /// `inactive`; without this guard that transient state would drop the cover
  /// and the user would return from the picker to the News screen. Set it true
  /// BEFORE opening the overlay and false immediately after it closes.
  static bool systemOverlayActive = false;

  @override
  ConsumerState<MilesApp> createState() => _MilesAppState();
}

class _MilesAppState extends ConsumerState<MilesApp>
    with WidgetsBindingObserver {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  Timer? _heartbeat;
  final _volumeChannel = const MethodChannel('miles/volume_keys');

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

    // Panic lock: shake ×3 or volume up+down → snap back to the News cover.
    // Detection only runs while the real app is visible and not already covered.
    EmergencyLockService.init(
      onLock: _emergencyLock,
      shouldDetect: () => MilesApp.showRealApp.value && !stealthActive.value,
    );
    // Bridge native hardware volume keys (Android consumes them before they
    // reach Flutter's key pipeline) for the combo + stealth dismiss.
    _volumeChannel.setMethodCallHandler(_onVolumeMethod);
  }

  /// Instantly drop to the News cover (shake / volume combo). No animation.
  void _emergencyLock() {
    MilesApp.showRealApp.value = false;
    stealthActive.value = false;
  }

  /// A native volume key-DOWN ('up' / 'down'). Volume-down dismisses the stealth
  /// scrim; while the scrim is up we swallow keys so a stray press can't seed
  /// the emergency combo. Otherwise (real app visible) feed the combo detector.
  Future<void> _onVolumeMethod(MethodCall call) async {
    if (call.method != 'volume') return;
    final dir = call.arguments as String?;
    if (dir == null) return;
    if (stealthActive.value) {
      if (dir == 'down') stealthActive.value = false;
      return;
    }
    if (MilesApp.showRealApp.value) {
      EmergencyLockService.handleVolumeDirection(dir);
    }
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
        // Real backgrounding → drop to the News cover immediately, UNLESS a
        // system overlay we deliberately opened (gallery/camera/file picker,
        // permission dialog) is up. A full-screen picker Activity obscures us
        // and reports `paused` on most Android builds — dropping then is exactly
        // what stranded the user on News (and lost the in-flight media) when
        // they returned from the picker. The guard is cleared in a finally the
        // instant the picker closes, so full stealth resumes immediately after.
        if (!MilesApp.systemOverlayActive) {
          MilesApp.showRealApp.value = false;
        }
      case AppLifecycleState.detached:
        MilesApp.showRealApp.value = false;
      case AppLifecycleState.inactive:
        // Transient focus loss: a picker grabbing focus, the notification-shade
        // peek, the biometric prompt. Defer the check a beat so the overlay
        // guard (set synchronously before opening any overlay) is definitely
        // visible, then drop ONLY if we're STILL inactive and nothing is
        // intentionally open — so a quick shade peek that returns to resumed
        // doesn't force an unnecessary re-auth, and a picker keeps the cover up.
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          if (MilesApp.authInProgress || MilesApp.systemOverlayActive) return;
          if (WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.inactive) {
            MilesApp.showRealApp.value = false;
          }
        });
      case AppLifecycleState.resumed:
        break;
    }

    // Biometric app-lock: raise on background, prompt to unlock on resume — but
    // only while the REAL app is visible, never unsolicited over the News cover,
    // and NOT while a system picker we opened is up (else picking a photo would
    // trip the lock and prompt biometrics on the way back).
    if (state == AppLifecycleState.paused && !MilesApp.systemOverlayActive) {
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
    _volumeChannel.setMethodCallHandler(null);
    EmergencyLockService.dispose();
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
        // Branded loading screen (never a white blank) for the 1–3s the session
        // takes to initialise right after authentication. Guard on profile==null
        // so this only shows on the FIRST load — a later background reload (token
        // refresh) keeps the old profile while loading flips true, so it won't
        // flash over the running app.
        final showSessionLoading = ref.watch(
          sessionProvider.select((s) => s.loading && s.profile == null),
        );
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
              // The routed screen, transparent so the glow shows through — or a
              // branded loading veil while the session is still initialising.
              if (showSessionLoading)
                const _SessionLoading()
              else
                child ?? const SizedBox.shrink(),
              // Return-to-call pill while a call is minimised.
              const CallPill(),
              // Biometric lock sits on top of everything.
              ValueListenableBuilder<bool>(
                valueListenable: AppLock.locked,
                builder: (context, locked, _) =>
                    locked ? const LockScreen() : const SizedBox.shrink(),
              ),
              // Stealth quick-cover: invisible top-right tap zone + scrim,
              // present on every screen inside the real app.
              const Positioned.fill(child: StealthLayer()),
            ],
          ),
        );
      },
    );
  }
}

/// Branded "session warming up" veil shown for the 1–3s between authentication
/// and the first profile/couple load — replaces the white blank that used to
/// flash while MaterialApp.router + the session providers initialised. Sits over
/// the always-present [EmberBackground], so it reads as the Tethered candlelight,
/// not a broken screen.
class _SessionLoading extends StatelessWidget {
  const _SessionLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Tethered',
            style: GoogleFonts.fraunces(
              fontSize: 32,
              fontStyle: FontStyle.italic,
              color: MilesColors.cream50,
            ),
          ),
          const SizedBox(height: 24),
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: MilesColors.ember,
            ),
          ),
        ],
      ),
    );
  }
}
