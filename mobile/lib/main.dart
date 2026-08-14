import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/config.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/emergency_lock_service.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/permissions_bootstrap.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/core/widgets/stealth_overlay.dart';
import 'package:miles/core/widgets/warmth_overlay.dart';
import 'package:miles/core/widgets/wordmark.dart';
import 'package:miles/features/call/call_pill.dart';
import 'package:miles/features/disguise/disguise_cover_host.dart';
import 'package:miles/firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      'ENV CHECK → url len: ${envUrl.length}, key len: ${envKey.length}',);
  if (envUrl.isEmpty || envKey.isEmpty) {
    throw StateError('Supabase env missing: ensure mobile/.env has '
        '${MilesConfig.supabaseUrlKey} and ${MilesConfig.supabaseAnonKeyKey}.');
  }

  // Independent of each other — three serial round-trips became one wait.
  // loadSetupFlag must still land before the first lifecycle event, or a
  // restart would hand the first-run cover exemption back to an already-set-up
  // device; awaiting the group preserves that.
  await Future.wait([
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    SupabaseService.init(),
    MilesApp.loadSetupFlag(),
    // Awaited rather than fired off, so the flush timer and the log file exist
    // before the first ICE callback. Diag.record() already works without it —
    // events queue — but a cold-start ordering bug is one of the things being
    // hunted, and losing the first three seconds would hide it.
    Diag.init(),
    // Before anything talks to the backend. A build below the minimum is told
    // to update rather than discovering it as a screen that will not load —
    // this app is sideloaded, so old versions never go away on their own.
    ReleaseGate.check(),
  ]);
  // Must be registered before runApp; runs in its own isolate when a push
  // arrives while the app is backgrounded or terminated. Needs Firebase ready.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  TzHelper.ensureInit();
  initRealtimeAutoResume(); // rejoin channels whenever the socket (re)connects
  // Off the critical path: nothing paints an ad or reads a push before the
  // News cover, the biometric gate and the splash are all behind us, and
  // AppShell drains the pending reach/call notifiers in its post-frame
  // callback. Awaiting these cost the first frame ~a dozen platform crossings.
  unawaited(FcmService.init());
  // Lets the call's background foreground-service talk to the UI isolate.
  FlutterForegroundTask.initCommunicationPort();
  debugPrint('STARTUP OK → booting app');

  runApp(const ProviderScope(child: MilesApp()));
}

class MilesApp extends ConsumerStatefulWidget {
  const MilesApp({super.key});

  /// Whether the real Miles app is shown (true) or the disguise cover
  /// (false). Reset to false on every background so returning always requires
  /// re-authentication; only FakeNewsScreen sets it true after the biometric +
  /// splash. Static so the cover screen and the lifecycle handler
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

  /// True once this device has reached a fully set-up state (signed in,
  /// onboarded, paired) at least once. Only a device that never got there gets
  /// the first-run cover exemption in [_MilesAppState.didChangeAppLifecycleState];
  /// afterwards the cover applies unconditionally, even if the couple is later
  /// disconnected. Persisted so a restart can't hand the exemption back.
  static bool setupCompletedOnce = false;
  static const _setupDoneKey = 'setup_completed_once';

  static Future<void> loadSetupFlag() async {
    setupCompletedOnce =
        (await SharedPreferences.getInstance()).getBool(_setupDoneKey) ?? false;
  }

  static Future<void> markSetupComplete() async {
    if (setupCompletedOnce) return;
    setupCompletedOnce = true;
    await (await SharedPreferences.getInstance()).setBool(_setupDoneKey, true);
  }

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
    _watchPasswordRecovery();
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
    // A beat that found no couple wrote nothing and said nothing, so a phone
    // whose couple never resolved produced the same empty trace as one whose
    // timer had stopped — and the partner reads offline either way.
    DateTime? prevBeat;
    void beat() {
      final c = ref.read(currentCoupleProvider);
      final now = DateTime.now();
      final prev = prevBeat;
      Diag.record(DiagArea.presence, 'presence_heartbeat', fields: {
        'action': c == null ? 'skip_no_couple' : 'beat',
        'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
        'has_couple': c != null,
        if (prev != null)
          'since_prev_beat_ms': now.difference(prev).inMilliseconds,
      },);
      prevBeat = now;
      if (c != null) PresenceService.setOnline(c.id, online: true);
    }

    Diag.record(DiagArea.presence, 'presence_heartbeat', fields: {
      'action': 'start',
      'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
    },);
    beat(); // immediate beat so we read online without waiting a cycle
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => beat());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Lifecycle is the backdrop every other trace is read against. "The
    // heartbeat stopped" and "the app was backgrounded" are the same log line
    // from two different distances, and without this you cannot tell a presence
    // bug from a user putting their phone in a pocket.
    Diag.record(DiagArea.app, 'lifecycle', fields: {'state': state.name});
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // The last events before a kill are the ones worth having, and Android
      // gives no warning before it takes the process. Nothing awaits this.
      unawaited(Diag.flush());
    }

    // SECURITY (cover layer): drop back to the News screen the instant the app
    // leaves the foreground, so returning ALWAYS requires re-authentication.
    // NEVER set it true here — only the entry flow does, after biometric +
    // splash. This must run before the AppLock/presence logic below.
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
          // First-time setup (sign-in → profile → couple) is exempt: nothing
          // private is on screen yet, and those forms bounce us through
          // `inactive` on every keyboard and system dialog — dropping to News
          // then made finishing account creation impossible.
          //
          // Gated on [MilesApp.setupCompletedOnce] so it really is FIRST-time.
          // Without that, disconnecting a partner later (which nulls `couple`
          // while the session stays live) would silently switch the cover off
          // for good, and the sign-out listener in build() wouldn't catch it
          // because the user is still authenticated.
          if (!MilesApp.setupCompletedOnce) {
            final session = ref.read(sessionProvider);
            if (!session.isAuthenticated ||
                session.profile?.isOnboarded != true ||
                session.couple == null) {
              return;
            }
            // Fully set up but the flag is still false — the listener in
            // build() never saw the transition (it resolved before the listener
            // was registered). Catch up here so the exemption can't outlive
            // setup no matter which of the two observes it first.
            MilesApp.markSetupComplete();
          }
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
      // Walk back into the room we left. `paused` fires for the photo picker
      // and the camera as well as a real app switch, so without this a user
      // attaching one picture goes invisible for the rest of the session.
      _clearScreenTimer?.cancel();
      presenceRouteObserver?.restore();
      unawaited(_refreshOnResume());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopHeartbeat();
      // Write offline hint + clear chat presence (kills phantom "is here"
      // avatar and stale seen/delivered ticks on the partner's screen).
      // Best-effort; the freshness TTL is the real safety net on a hard kill.
      PresenceService.setOnline(couple.id, online: false);
      PresenceService.clearChatPresence(couple.id);
      // Leave the room as well as the app. Without this the last published
      // screen stood for up to 45s (the freshness window) after the app was
      // closed, so a partner could be looking at "she's in the chat with me"
      // when she had put the phone down. Presence must decay to unknown, never
      // linger as a confident wrong answer.
      // Deferred, not immediate. The disguise cover flips this app through
      // inactive/hidden/paused every few seconds, and a trace showed the
      // consequence on the other phone: presence_screen_recv screen_null=true,
      // then has_screen=false — the partner could not see which room you were
      // in because it was being cleared faster than it was being published.
      //
      // A real background outlives this timer; a cover flip, a picker and the
      // notification shade do not. The 45s freshness window still decays an
      // abandoned screen on its own, so nothing lingers as a confident wrong
      // answer if the process dies inside the delay.
      _clearScreenTimer?.cancel();
      _clearScreenTimer = Timer(const Duration(seconds: 6), () {
        final st = WidgetsBinding.instance.lifecycleState;
        if (st == AppLifecycleState.resumed) return;
        presenceRouteObserver?.clear();
      });
    }
  }

  Timer? _clearScreenTimer;

  /// The last time a resume refresh ran, so a burst of lifecycle events — and
  /// Android sends several — costs one refresh, not five.
  DateTime? _lastResumeRefresh;

  /// Bring the app up to date on return, rather than on a full restart.
  ///
  /// Realtime rejoins on resume, but it only carries what happens AFTER it
  /// reconnects: anything that changed while the socket was down is simply
  /// missed. So the app looked stale until it was killed and relaunched, which
  /// is the one action that forces a fresh read of everything.
  ///
  /// Deliberately narrow. This fires on every return from every picker and
  /// camera, for every user — a fan-out of queries here is a scaling defect,
  /// not a fix. Session and timezone only; screens that need more refresh
  /// themselves.
  Future<void> _refreshOnResume() async {
    final last = _lastResumeRefresh;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _lastResumeRefresh = DateTime.now();
    try {
      final session = ref.read(sessionProvider.notifier);
      await session.loadProfile();
      // Cheap, and the one thing that silently goes wrong when someone travels.
      unawaited(session.syncTimezone());
    } catch (e) {
      debugPrint('[resume] refresh failed: $e');
    }
  }

  /// Route to the new-password screen the moment a recovery session opens.
  ///
  /// Listened for here rather than in the router redirect because the event is
  /// asynchronous: by the time it fires the user is already sitting on
  /// whichever route the funnel chose, and only a push moves them.
  void _watchPasswordRecovery() {
    passwordRecovery.addListener(_routeToNewPassword);
    // The event usually lands while the cover is still up, so the flip to the
    // real app is the second chance to act on it.
    MilesApp.showRealApp.addListener(_routeToNewPassword);
    MilesApp.showRealApp.addListener(_dropPlaintextBehindCover);
  }

  /// Every decrypted photograph leaves RAM the moment the cover goes up.
  ///
  /// One listener rather than a call at each of the five places that lower
  /// [MilesApp.showRealApp] — the shake, the volume combo, the lifecycle hook,
  /// the app lock and the stealth scrim — because missing one of them is
  /// missing all of them, and the failure is invisible.
  ///
  /// A screen's `dispose()` cannot do this job: the cover is raised on
  /// backgrounding, which is exactly when Android kills the process, so
  /// `dispose` frequently never runs. Only the ciphertext on disk survives,
  /// which is the whole design.
  void _dropPlaintextBehindCover() {
    if (MilesApp.showRealApp.value) return;
    EncryptedMediaCache.clear();
  }

  /// The router only exists while the real app is on screen — below that, the
  /// cover has replaced the whole widget tree. A recovery event arriving behind
  /// it must be HELD rather than consumed: clearing the flag to push a route
  /// nobody is rendering drops the user into the app still not knowing their
  /// password, with nothing left to route on.
  void _routeToNewPassword() {
    if (!passwordRecovery.value || !mounted) return;
    if (!MilesApp.showRealApp.value) return;
    passwordRecovery.value = false;
    ref.read(routerProvider).go('/new-password');
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
  ///
  /// tethered://auth-callback (email confirmation, password recovery) needs no
  /// token handling here: supabase_flutter parses those off the incoming link
  /// itself and emits the auth event. What it cannot do is get the app out from
  /// behind the cover, which is exactly where opening the inbox left it — so
  /// that half is ours. See [pendingAuthLink].
  void _handleLink(Uri uri) {
    if (uri.scheme != 'tethered') return;
    if (uri.host == 'auth-callback') {
      // The scheme alone is not evidence. MainActivity is exported and this
      // intent-filter carries BROWSABLE, so a bare
      // Intent(ACTION_VIEW, "tethered://auth-callback") from any installed app
      // — or a link on any web page — used to set this, and CoverGate then ran
      // runEntryGate() unconditionally. With no app lock enrolled, which is the
      // default, that dropped the disguise on a third party's say-so.
      //
      // A real Supabase callback carries the material it is redeeming. This
      // narrows the caller from "anyone" to "anyone who also supplies a
      // plausible token", and is the interim: the durable fix is to raise this
      // off the auth-state stream (passwordRecovery / signedIn arriving while
      // showRealApp is false) rather than off an intent at all.
      const proof = ['code', 'access_token', 'refresh_token', 'token', 'type'];
      final q = uri.queryParameters;
      final frag = uri.fragment.isEmpty
          ? const <String, String>{}
          : Uri.splitQueryString(uri.fragment);
      final carries = proof.any((k) =>
          (q[k]?.isNotEmpty ?? false) || (frag[k]?.isNotEmpty ?? false));
      if (!carries) return;
      pendingAuthLink.value = true;
      return;
    }
    if (uri.host != 'join') return;
    final raw = uri.queryParameters['code'];
    if (raw == null || raw.isEmpty) return;
    // Same reasoning one step further in: this is pre-filled into the pairing
    // field from an unauthenticated caller, so it is bounded to the shape the
    // server actually mints (8 hex characters, create_pairing_invite) rather
    // than pushed through verbatim.
    final code = raw.toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6,12}$').hasMatch(code)) return;
    ref.read(pendingInviteCodeProvider.notifier).state = code;
    ref.read(routerProvider).go('/couple');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    passwordRecovery.removeListener(_routeToNewPassword);
    MilesApp.showRealApp.removeListener(_routeToNewPassword);
    MilesApp.showRealApp.removeListener(_dropPlaintextBehindCover);
    _volumeChannel.setMethodCallHandler(null);
    EmergencyLockService.dispose();
    _stopHeartbeat();
    _sub?.cancel();
    // Fires up to 6s after a pause and touches presenceRouteObserver. Left
    // pending it outlives the state that owns it, and a widget test that
    // disposes the tree fails on the timer rather than on what it was testing.
    _clearScreenTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SessionState>(sessionProvider, (previous, next) {
      // Signing out from inside the app drops straight back to the News cover,
      // rather than leaving the unmistakably-not-a-news-app sign-in screen on
      // display. Also what stops the first-run exemption in
      // didChangeAppLifecycleState from stranding a logged-out session
      // uncovered.
      if ((previous?.isAuthenticated ?? false) && !next.isAuthenticated) {
        MilesApp.showRealApp.value = false;
      }
      // Setup finished → the first-run exemption is spent, permanently.
      if (next.isAuthenticated &&
          (next.profile?.isOnboarded ?? false) &&
          next.couple != null) {
        MilesApp.markSetupComplete();
      }
      // Diagnostics can only be uploaded once there is a couple to scope the
      // rows to. Bound from the session listener rather than read once, because
      // the couple resolves asynchronously — reading it at startup is precisely
      // the mistake that leaves presence bound to null forever.
      Diag.bind(coupleId: next.couple?.id, userId: next.profile?.id);

      // The couple resolves LATE, and goes null again on every resume — a
      // traced session skipped seven consecutive heartbeats across three and a
      // half minutes, during which the partner simply read "offline".
      //
      // Nothing used to notice it coming back. The heartbeat waited out its
      // 30s cycle and the screen a user was already sitting on was never
      // published at all. Both are driven off the transition now.
      final gained = previous?.couple == null && next.couple != null;
      if (gained) {
        _startHeartbeat();
        presenceRouteObserver?.flushDeferred();
      }
    });

    // ref.listen fires on CHANGE only, so a session that had already resolved
    // before this widget first built would never bind and nothing would ever
    // upload — the same shape as the presence bug being hunted, in the code
    // added to hunt it. Diag.bind is a no-op when nothing changed.
    final session = ref.read(sessionProvider);
    Diag.bind(coupleId: session.couple?.id, userId: session.profile?.id);

    // The cover/real swap is driven by the static showRealApp notifier so the
    // lifecycle handler (and FakeNewsScreen) can flip it without setState.
    return ValueListenableBuilder<bool>(
      valueListenable: MilesApp.showRealApp,
      builder: (context, isReal, _) {
        // Cover layer: a convincing "News" app shown on cold start and the
        // instant the app backgrounds. Only a secret trigger + biometric pass +
        // the splash swaps in the real app. Its clean light theme shares
        // nothing with Miles' Emberlight dark theme.
        // An out-of-date build stops here, above the cover and the lock: the
        // parts below it assume a schema this build may no longer understand.
        if (ReleaseGate.isBlocked) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              backgroundColor: MilesColors.night,
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.system_update,
                          color: MilesColors.ember, size: 44,),
                      const SizedBox(height: 20),
                      Text(
                        ReleaseGate.message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: MilesColors.cream50, fontSize: 16, height: 1.5,),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        if (!isReal) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: Brightness.light,
              scaffoldBackgroundColor: Colors.white,
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF1A73E8),
              ),
              useMaterial3: true,
            ),
            home: DisguiseCoverHost(
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
          // Empty so the task switcher shows the chosen alias label. This one
          // matters most: it is the REAL app's task description, and a
          // hardcoded name here leaks straight into recents.
          title: '',
          debugShowCheckedModeBanner: false,
          theme: milesDarkTheme(),
          routerConfig: router,
          builder: (context, child) => Stack(
            children: [
              // Always-present candle-glow backdrop. It shows at the edges and
              // behind transparent scaffolds; panels drawn over it are opaque.
              const EmberBackground(child: SizedBox.shrink()),
              // The routed screen, transparent so the glow shows through — or a
              // branded loading veil while the session is still initialising.
              if (showSessionLoading)
                const _SessionLoading()
              else
                child ?? const SizedBox.shrink(),
              // Return-to-call pill while a call is minimised.
              // These three animate independently of the routed screen, so each
              // gets its own layer — a pulsing badge must not repaint the page
              // beneath it.
              const RepaintBoundary(child: CallPill()),
              // Presence used to float here, top-centre over every screen. It
              // covered titles and buttons, interrupted whatever was being
              // read, and looked like a system alert instead of a person. It
              // now lives in each screen's own AppBar next to their name —
              // see PartnerHereAction.
              // The shared bloom when one of them warms the room. Root-level
              // so it reaches the whole screen, above the page and below the
              // lock.
              const Positioned.fill(child: WarmthOverlay()),
              // Biometric lock sits on top of everything.
              RepaintBoundary(
                child: ValueListenableBuilder<bool>(
                  valueListenable: AppLock.locked,
                  builder: (context, locked, _) =>
                      locked ? const LockScreen() : const SizedBox.shrink(),
                ),
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
/// the always-present [EmberBackground], so it reads as the Miles candlelight,
/// not a broken screen.
class _SessionLoading extends StatelessWidget {
  const _SessionLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Wordmark(size: 32),
          SizedBox(height: 24),
          SizedBox(
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
