import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/ads/ad_service.dart';
import 'package:miles/core/providers.dart';
import 'package:miles/core/router.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Must be registered before runApp; runs in its own isolate when a push
  // arrives while the app is backgrounded or terminated.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  TzHelper.ensureInit();
  await SupabaseService.init();
  await AdService.init();
  await FcmService.init();

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
    _initDeepLinks();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
    );
  }
}
