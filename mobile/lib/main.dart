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
import 'package:miles/core/router.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/permissions_bootstrap.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/features/call/call_pill.dart';
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
  await AdService.init();
  await FcmService.init();
  // Lets the call's background foreground-service talk to the UI isolate.
  FlutterForegroundTask.initCommunicationPort();
  debugPrint('STARTUP OK → booting app');

  runApp(const ProviderScope(child: MilesApp()));
}

class MilesApp extends ConsumerStatefulWidget {
  const MilesApp({super.key});

  @override
  ConsumerState<MilesApp> createState() => _MilesAppState();
}

class _MilesAppState extends ConsumerState<MilesApp>
    with WidgetsBindingObserver {
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Biometric app-lock: raise on background, prompt to unlock on resume.
    if (state == AppLifecycleState.paused) {
      AppLock.lockIfEnabled();
    } else if (state == AppLifecycleState.resumed && AppLock.locked.value) {
      AppLock.authenticate(); // re-prompt on return
    }
    final couple = ref.read(currentCoupleProvider);
    if (couple == null) return;
    PresenceService.setOnline(
      couple.id,
      online: state == AppLifecycleState.resumed,
    );
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
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Tethered',
      debugShowCheckedModeBanner: false,
      theme: milesDarkTheme(),
      routerConfig: router,
      builder: (context, child) => Stack(
        children: [
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
  }
}
