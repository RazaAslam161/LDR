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
import 'package:miles/core/app/logging.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/media/encrypted_media_cache.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:miles/core/services/sound/miles_sound.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/services/emergency_lock_service.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/widgets/partner_here_badge.dart' show partnerScreenProvider;
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/services/update_service.dart';
import 'package:miles/core/time/tz_helper.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/lock_screen.dart';
import 'package:miles/core/widgets/stealth_overlay.dart';
import 'package:miles/core/widgets/update_sheet.dart';
import 'package:miles/core/widgets/warmth_overlay.dart';
import 'package:miles/core/widgets/wordmark.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/call/call_pip.dart';
import 'package:miles/features/call/pip_mode.dart';
import 'package:miles/features/call/screen_share_banner.dart';
import 'package:miles/features/disguise/disguise_cover_host.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/features/legal/terms_gate.dart';
import 'package:miles/features/safety/contact_pause.dart';
import 'package:miles/features/unlink/unlink_banner.dart';
import 'package:miles/firebase_options.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState;
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  // First statement on purpose: it touches no binding, and going first covers
  // the env-check log below too. Shipped logs name partners, couple ids and
  // message ids, and anyone with `adb logcat` reads them off a handset whose
  // whole design goal is looking like something else.
  silenceLogsInRelease();
  WidgetsFlutterBinding.ensureInitialized();

  // ── Global error nets. Keep one bad async error from blanking a whole
  //    feature, and — the part that was missing — tell somebody. Both handlers
  //    used to debugPrint and stop there, which reaches a logcat, which reaches
  //    whichever handset has a cable in it. Registered first, before anything
  //    that can throw.
  FlutterError.onError = (details) {
    ErrorReporter.report(details.exception, details.stack, kind: 'flutter');
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    ErrorReporter.report(error, stack, kind: 'platform');
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
    // Which channel this is. Awaited here rather than read where it is needed
    // because the answer decides whether the first frame is a cover at all —
    // asking later would flash one on a build that has no disguise to show.
    DisguiseService.loadEnabled(),
    // Whether this channel may install its own APK. Read here rather than at
    // the point of use so the answer is settled before AppShell can offer one.
    UpdateService.loadAllowed(),
    // One-time chore, not instrumentation: clears the retired upload flag and
    // deletes the trace file every install still carries. Runs until every
    // handset has run it once.
    Diag.init(),
  ]);
  // Deliberately AFTER that group rather than inside it. SupabaseService.client
  // is a `late final` assigned on the LAST line of init(), so anything sharing
  // the same Future.wait reads it before it is assigned. ReleaseGate.check sat
  // in that group and had therefore never once run: it threw
  // LateInitializationError into its own fail-open catch on every launch,
  // logging "gate unreachable, allowing" and taking the min_build block with
  // it — and UpdateService.available, which needs the apkUrl only check()
  // assigns.
  //
  // Both awaited, because the first frame consults both and neither has
  // anything to rebuild it later: the redirect reads TermsGate on its very
  // first evaluation (unawaited, an account that agreed months ago is bounced
  // to the terms for a frame and back out again), and MilesApp.build reads
  // ReleaseGate.isBlocked, a plain static with no listenable.
  await Future.wait([TermsGate.load(), ReleaseGate.check()]);
  // Crash reports parked by launches that could not deliver them — signed out,
  // offline, or dead before SupabaseService.init assigned the client. Sent now
  // because reaching this line is the thing those launches failed to do, and
  // below the group above so the client exists to send with. Not awaited: the
  // first frame owes nothing to old crashes, and it never throws.
  unawaited(ErrorReporter.flushBuffered());
  // Not awaited: nothing before the first frame reads it, and the server-side
  // mute is the real enforcement — this copy only exists so the ring that
  // arrives over the realtime channel can be dropped too.
  unawaited(ContactPause.load());
  // The sound layer: its toggle from prefs, and the two ambient facts its
  // gate chain reads — handed down as functions because everything imports
  // the facade and the facade must not import main.
  unawaited(MilesSound.loadPref());
  MilesSound.wireProbes(
    coverVisible: () => !MilesApp.showRealApp.value,
    // BOTH call shapes: PiP (a cue over the minimised conversation) and the
    // full-screen call (the chat stays mounted beneath it and its receive
    // cue would play into the mic path).
    callActive: () => PipMode.active.value || CallController.liveCall.value,
  );
  // A recheck can flip the fleet kill mid-session; a running bed dies with it.
  MilesSound.attachKillSwitch();
  // Warm the pool when the real app comes up; SILENCE THE INSTANT it drops.
  // The cover rises on the panic gesture and on sign-out with the app still
  // foregrounded — no lifecycle event fires, so the silence must ride the
  // same edge the cover does. One second of ceremony audio under a panic
  // cover is the exact tell the cover exists to prevent.
  MilesApp.showRealApp.addListener(() {
    if (MilesApp.showRealApp.value) {
      unawaited(MilesSound.warm());
    } else {
      unawaited(MilesSound.silenceAll());
    }
  });
  // No disguise on this channel means no door to come through: the real app is
  // the first frame, and MilesApp.raiseCover keeps it that way.
  if (!DisguiseService.enabled) MilesApp.showRealApp.value = true;
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
  PipMode.wire();
  debugPrint('STARTUP OK → booting app');

  runApp(const ProviderScope(child: MilesApp()));
}

class MilesApp extends ConsumerStatefulWidget {
  const MilesApp({super.key});

  /// Whether the real Miles app is shown (true) or the disguise cover
  /// (false). Reset to false on every background so returning always requires
  /// re-authentication; only NewsCoverScreen sets it true after the biometric +
  /// splash. Static so the cover screen and the lifecycle handler
  /// share one source of truth.
  ///
  /// On a channel with no disguise it starts true in main() and stays true —
  /// see [raiseCover].
  static final ValueNotifier<bool> showRealApp = ValueNotifier<bool>(false);

  /// Puts the cover back up.
  ///
  /// The only way down — the panic gestures, each lifecycle transition, and
  /// sign-out — because the play channel ships no disguise at all, and a flag
  /// lowered anywhere ungated there hands a Play reviewer an honestly-named app
  /// that opens on a fake news reader. Missing one caller is missing all of
  /// them, and the failure is a screen nobody can get past.
  static void raiseCover() {
    if (DisguiseService.enabled) showRealApp.value = false;
  }

  /// True only while an OS unlock prompt is on screen. The prompt itself makes
  /// the app `inactive` (biometric overlay) or `paused` (the PIN/pattern
  /// credential Activity); this guards both transitions from resetting
  /// [showRealApp] and tearing down the tree mid-auth.
  ///
  /// Delegates to [AppLock.authInProgress] — one backing bool, set inside
  /// AppLock.authenticate() itself, so callers that never touch this class
  /// (partner_rewrap.dart demands the unlock from core code) are guarded too.
  static bool get authInProgress => AppLock.authInProgress;
  static set authInProgress(bool v) => AppLock.authInProgress = v;

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
  StreamSubscription<AuthState>? _authSub;
  Timer? _heartbeat;
  final _volumeChannel = const MethodChannel('miles/volume_keys');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // No first-frame permission blast. Camera, microphone, notifications and
    // media were all requested here, before sign-up and before the user had
    // seen a screen — the same reasoning the old bootstrap gave for leaving
    // location OUT of it. Android makes a second refusal permanent, so a
    // deny-first user lost calls, voice notes and capture for good, silently.
    // Every one of them is asked for at its point of use instead.
    //
    // If the user enabled the biometric app-lock, raise it on launch. The
    // LockScreen auto-prompts biometrics when it appears.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => AppLock.lockIfEnabled());
    _initDeepLinks();
    _watchAuthLinkRedemption();
    _watchPasswordRecovery();
    _startHeartbeat(); // app launches foregrounded

    // Panic lock: shake ×3 or volume up+down → snap back to the News cover.
    // Detection only runs while the real app is visible and not already covered.
    EmergencyLockService.init(
      onLock: _emergencyLock,
      shouldDetect: () =>
          DisguiseService.enabled &&
          MilesApp.showRealApp.value &&
          !stealthActive.value,
    );
    // Bridge native hardware volume keys (Android consumes them before they
    // reach Flutter's key pipeline) for the combo + stealth dismiss.
    _volumeChannel.setMethodCallHandler(_onVolumeMethod);
  }

  /// Instantly drop to the News cover (shake / volume combo). No animation.
  void _emergencyLock() {
    MilesApp.raiseCover();
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
      // ONLINE MEANS A PERSON IS LOOKING AT THIS APP. Not "the process is
      // running", which is what this used to mean and why a Reach made the
      // recipient appear online without her touching the phone: a push resumes
      // the app, resume started the heartbeat, and the first beat stamped
      // is_online, app_last_active_at and last_seen — all three — while the
      // disguise cover was still up and she had not authenticated.
      //
      // That is worse than a cosmetic bug. The sender is told his partner is
      // there and reading, when she is asleep with the phone face down, and
      // what he does with that belief is have an argument about being ignored.
      //
      // showRealApp is only true after the cover, the biometric gate and the
      // splash are all behind us — which no push can fake.
      if (!MilesApp.showRealApp.value) return;
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
        // PiP is the other exemption. Android reports `paused` for a picture-
        // in-picture window, so the cover would come up INSIDE the floating
        // call — showing News where her face should be, which is both useless
        // and a louder tell than the call was.
        // authInProgress is the third exemption: the PIN/pattern flavour of
        // the OS unlock is a full Activity and reports `paused`, not
        // `inactive` — raising the cover here swapped the MaterialApp and
        // destroyed the very screen (the rewrap ceremony) whose unlock was in
        // progress, taking the typed code with it.
        if (!MilesApp.systemOverlayActive &&
            !PipMode.active.value &&
            !MilesApp.authInProgress) {
          MilesApp.raiseCover();
        }
        // Sound goes silent on ANY real backgrounding, cover or not — a bed
        // playing from a pocket is the tell the cover exists to prevent.
        unawaited(MilesSound.silenceAll());
      case AppLifecycleState.detached:
        MilesApp.raiseCover();
        unawaited(MilesSound.silenceAll());
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
            MilesApp.raiseCover();
          }
        });
      case AppLifecycleState.resumed:
        break;
    }

    // Biometric app-lock: raise on background, prompt to unlock on resume — but
    // only while the REAL app is visible, never unsolicited over the News cover,
    // and NOT while a system picker we opened is up (else picking a photo would
    // trip the lock and prompt biometrics on the way back).
    if (state == AppLifecycleState.paused &&
        !MilesApp.systemOverlayActive &&
        !MilesApp.authInProgress) {
      // Without the authInProgress guard the ceremony's own prompt set
      // `locked`, and the user unlocked twice back to back.
      AppLock.lockIfEnabled();
    } else if (state == AppLifecycleState.resumed) {
      if (MilesApp.showRealApp.value && AppLock.locked.value) {
        AppLock.authenticate(); // re-prompt on return
      }
      // Refresh the FCM token every resume — self-heals a token the notify
      // functions nulled server-side (UNREGISTERED), restoring pushes.
      FcmService.registerToken();
      // Re-read the release gate. It ran once in main() into plain statics, so a
      // phone Android kept alive never saw a release published while it sat in
      // the background — the update went only to whoever cold started after it.
      // Throttled internally; the notifier drives the block screen and the
      // update sheet without a restart.
      unawaited(ReleaseGate.recheck());
      // We are foregrounded, so by definition no overlay we opened is still in
      // front. Pickers clear this in their own `finally`; the install-permission
      // screen has no result to await and can only be cleared here.
      MilesApp.systemOverlayActive = false;
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
      _offlineTimer?.cancel();
      presenceRouteObserver?.restore();
      unawaited(_refreshOnResume());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _stopHeartbeat();
      _goOffline(couple.id, dying: state == AppLifecycleState.detached);
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

  /// Say goodbye, so the partner's avatar SWITCHES off instead of decaying.
  ///
  /// The write itself is not new — `is_online:false` has always been sent here.
  /// What is new is that [Presence.saidGoodbye] reads it, so it now has to be
  /// right rather than merely advisory. Two consequences:
  ///
  /// 1. Never during an overlay we opened. A full-screen picker, the camera and
  ///    a PiP call all report `paused` on most Android builds. The same guard
  ///    the cover uses (:305) applies for the same reason — attaching one photo
  ///    must not tell the partner you left.
  /// 2. Settled, not instant, on `paused`. The disguise cover flips this app
  ///    through inactive/hidden/paused every few seconds, and the traced cost of
  ///    treating each flip as real is recorded above this. 1.5s is five times
  ///    the 300ms the `inactive` branch already treats as transient, and still
  ///    thirty times faster than the 45-75s decay it replaces.
  ///
  /// `detached` is the process dying — a timer would never run, so write it now.
  /// If the process dies inside the settle window nothing is written at all, and
  /// the 45s freshness window catches it exactly as it does a force-kill.
  ///
  /// Fire-and-forget: the cover is already up by the time this is reached, and
  /// nothing here is awaited on the path to raising it.
  void _goOffline(String coupleId, {required bool dying}) {
    _offlineTimer?.cancel();
    if (MilesApp.systemOverlayActive || PipMode.active.value) return;
    // Announced with NO settle, deliberately. The settle below guards the
    // durable write against a momentary pause; the broadcast does not need it,
    // because if this turns out to be a blink the resume path announces `true`
    // again within a few hundred milliseconds and the hint's timestamp ordering
    // sorts it out. A brief flicker is a better trade than a second of watching
    // somebody who has already gone.
    ref.read(partnerScreenProvider.notifier).announceLive(online: false);
    if (dying) {
      unawaited(PresenceService.setOnline(coupleId, online: false));
      return;
    }
    // 500ms, down from 1500. The settle exists so a momentary pause does not
    // blink the partner offline, but the two causes of a momentary pause are
    // already excluded above — a system overlay we opened, and PiP — so the
    // long wait was protecting against a case the guards had taken. It cost the
    // partner over a second of watching an avatar that had already left, and
    // the re-check below still cancels a false positive.
    _offlineTimer = Timer(const Duration(milliseconds: 500), () {
      if (WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed) {
        return;
      }
      unawaited(PresenceService.setOnline(coupleId, online: false));
    });
  }

  Timer? _offlineTimer;
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

  /// Raise the cover when a mail link is actually redeemed.
  ///
  /// Reading the link opens a mail app, which backgrounds this one and drops it
  /// to the cover; the link then wakes it behind that cover, where the router
  /// does not exist. The user is looking at a calculator with nothing to say it
  /// worked.
  ///
  /// Driven from the auth stream rather than from the incoming intent, because
  /// only the stream is evidence: a session appears here exactly when gotrue
  /// has redeemed a real token against the real server, which no third-party
  /// app can cause. See [_handleLink].
  void _watchAuthLinkRedemption() {
    _authSub = SupabaseService.authChanges.listen((event) {
      // These two events only, and the narrowness is the whole point.
      //
      // onAuthStateChange is a BehaviorSubject: it replays its last value to
      // every new subscriber and it emits `tokenRefreshed` on a timer. Reacting
      // to "there is a session" would therefore lift the cover on the replayed
      // `initialSession` of every ordinary launch, and again at each silent
      // token refresh — turning the disguise off for everyone who simply has an
      // account. `signedIn` and `passwordRecovery` are what a redeemed mail
      // link produces, and a normal sign-in raises neither from behind the
      // cover because the user is already looking at the real app by then.
      if (event.event != AuthChangeEvent.signedIn &&
          event.event != AuthChangeEvent.passwordRecovery) {
        return;
      }
      if (event.session == null) return;
      if (MilesApp.showRealApp.value) return;
      pendingAuthLink.value = true;
    }, onError: (Object e, StackTrace s) {
      // A dead or already-spent link throws inside getSessionFromUrl, and
      // gotrue pushes that as a stream ERROR rather than a value. With no
      // handler it became an unhandled zone error and the user — who is looking
      // at the cover, because opening the mail app raised it — saw a calculator
      // and nothing else, forever. Raising the cover here is what turns a
      // silent dead end into a screen that can say so.
      ErrorReporter.report(e, s, kind: 'auth-link');
      if (!MilesApp.showRealApp.value) pendingAuthLink.value = true;
    },);
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
    MilesApp.showRealApp.addListener(_trackHumanPresence);
    // Seed it: the real app is already showing on a channel with no disguise,
    // where showRealApp is set true in main() before this listener exists and
    // would therefore never fire.
    _trackHumanPresence();
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
  /// Presence follows the person, not the process.
  ///
  /// The cover coming down is the only signal that survives every way this app
  /// can be woken without her: a push, a widget, a system restart, the OS
  /// pre-warming the process. None of those get past the biometric gate, so
  /// none of them can claim she is online.
  ///
  /// Going true also beats immediately rather than waiting up to 30s for the
  /// heartbeat's next tick — she opens the app and her partner sees it now.
  void _trackHumanPresence() {
    final present = MilesApp.showRealApp.value;
    PresenceService.humanPresent = present;
    if (!present) return;
    final c = ref.read(currentCoupleProvider);
    if (c == null) return;
    // The socket first — it lands on her phone in ~100ms. The write below is
    // the durable record and takes a database round trip plus a
    // postgres_changes hop to become visible, which is the second-and-a-bit
    // that made arriving feel slow.
    ref.read(partnerScreenProvider.notifier).announceLive(online: true);
    unawaited(PresenceService.setOnline(c.id, online: true));
  }

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
  /// tethered://auth-callback (email confirmation, password recovery) is
  /// deliberately ignored here. supabase_flutter parses the token off the
  /// incoming link itself; getting the app out from behind the cover is the
  /// half that is ours, and it is raised from the auth stream instead — see
  /// [_watchAuthLinkRedemption] and [pendingAuthLink].
  void _handleLink(Uri uri) {
    if (uri.scheme != 'tethered') return;
    if (uri.host == 'auth-callback') {
      // The intent is not evidence, and no test of its contents can make it
      // evidence. MainActivity is exported and this filter carries BROWSABLE,
      // so any installed app — or any web page — can send
      // Intent(ACTION_VIEW, "tethered://auth-callback"). Raising the cover on
      // that dropped the disguise on a third party's say-so, and the guard that
      // replaced it only asked whether the caller had also supplied one of five
      // query parameters. `type` is a public constant: `?type=recovery` passed.
      //
      // What cannot be forged is the session actually changing, which only
      // happens if gotrue redeemed a real token against the real server.
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
    MilesApp.showRealApp.removeListener(_trackHumanPresence);
    _volumeChannel.setMethodCallHandler(null);
    EmergencyLockService.dispose();
    _stopHeartbeat();
    _sub?.cancel();
    _authSub?.cancel();
    // Fires up to 6s after a pause and touches presenceRouteObserver. Left
    // pending it outlives the state that owns it, and a widget test that
    // disposes the tree fails on the timer rather than on what it was testing.
    _clearScreenTimer?.cancel();
    _offlineTimer?.cancel();
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
        MilesApp.raiseCover();
      }
      // Setup finished → the first-run exemption is spent, permanently.
      if (next.isAuthenticated &&
          (next.profile?.isOnboarded ?? false) &&
          next.couple != null) {
        MilesApp.markSetupComplete();
      }
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

    // The cover/real swap is driven by the static showRealApp notifier so the
    // lifecycle handler (and NewsCoverScreen) can flip it without setState.
    return ValueListenableBuilder<int>(
      // Rebuilds when a resume re-check changes the answer, so a build that
      // falls below min_build while running shows the block screen then —
      // not on the next cold start, which for a backgrounded app may be days.
      valueListenable: ReleaseGate.revision,
      builder: (context, _, __) => ValueListenableBuilder<bool>(
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
                      // A blocked client can now rescue itself instead of being
                      // told to go find an APK by hand — the whole reason the
                      // self-updater exists. On the play build the way out is
                      // the store listing instead: a block screen with no
                      // button at all is a dead end on exactly the install
                      // that must update.
                      //
                      // The store button is gated on the CHANNEL, never on
                      // !available: available goes false on a sideload phone
                      // too (slow platform call, no APK published yet), and
                      // sending that phone to Play offers it a release-signed
                      // package over a debug-signed install — refused, and the
                      // uninstall "fix" wipes secure storage and the X25519
                      // seed with it.
                      if (UpdateService.available) ...[
                        const SizedBox(height: 28),
                        Builder(
                          builder: (ctx) => ElevatedButton(
                            onPressed: () =>
                                showUpdateSheet(ctx, mandatory: true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: MilesColors.ember,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 32, vertical: 14,),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),),
                            ),
                            child: const Text('Update now',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600,),),
                          ),
                        ),
                      ] else if (ReleaseGate.channel == 'play') ...[
                        const SizedBox(height: 28),
                        ElevatedButton(
                          onPressed: () async {
                            // market:// lands inside the Play app; a device
                            // without one gets the web listing, which any
                            // browser renders. Both failures are logged —
                            // this button is the only exit on this screen.
                            const id = 'com.miles.miles';
                            try {
                              if (await launchUrl(
                                Uri.parse('market://details?id=$id'),
                              )) {
                                return;
                              }
                            } catch (e) {
                              debugPrint('[release] market launch failed: '
                                  '${e.runtimeType}');
                            }
                            try {
                              await launchUrl(
                                Uri.parse(
                                  'https://play.google.com/store/apps/details?id=$id',
                                ),
                                mode: LaunchMode.externalApplication,
                              );
                            } catch (e) {
                              debugPrint('[release] store listing failed: '
                                  '${e.runtimeType}');
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: MilesColors.ember,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 32, vertical: 14,),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),),
                          ),
                          child: const Text('Update on Google Play',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600,),),
                        ),
                      ],
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
          // The backdrop WRAPS the whole overlay stack rather than sitting
          // beside it. As a Stack sibling its dedupe scope covered nothing —
          // an InheritedWidget only reaches descendants — so all 13 screens
          // that wrap themselves in EmberBackground were full painting
          // instances over a root that kept burning frames under their opaque
          // fills. As the ancestor, every one of them collapses to the
          // pass-through the scope always promised.
          // Both of this app's own covers — the biometric LockScreen and the
          // long-press stealth scrim — are SIBLINGS in the stack below, not
          // routes and not overlay entries. Flutter's own TickerMode only
          // reaches route- and overlay-scoped subtrees, so nothing under a
          // raised cover was ever muted: the ember field kept painting, the
          // hero card kept breathing, and the parallax kept streaming the
          // accelerometer at 15Hz behind a screen whose entire purpose is to
          // show nothing. One wrapper closes it for every ambient widget at
          // once, including the field itself.
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: AppLock.locked,
            builder: (context, locked, _) => ValueListenableBuilder<bool>(
              valueListenable: stealthActive,
              builder: (context, stealth, __) => Stack(
                children: [
                  TickerMode(
                enabled: !locked && !stealth,
                child: EmberBackground(
            child: Stack(
            children: [
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
              // The minimised call, as a real video window rather than a pill.
              // Above the routed screen so it survives every push — including
              // Watch Together, which is the whole point.
              // NOT wrapped. CallPip returns a Positioned, and Positioned
              // must be a DIRECT child of Stack — a RepaintBoundary between
              // them throws "Incorrect use of ParentDataWidget" and takes the
              // whole overlay layer down, which greys out the entire app and
              // swallows every touch. The boundary lives inside CallPip.
              const CallPip(),
              // Same rule as CallPip — returns a Positioned, so it must stay a
              // direct child of this Stack. Root-level because the moments it
              // exists for are precisely the ones where the call screen is not
              // the thing on top: a share that has walked into a FLAG_SECURE
              // screen is sending the partner a black rectangle, and neither of
              // them could previously tell that from a broken share.
              const ScreenShareBanner(),
              // The unlinking ceremony's presence, app-wide and tappable —
              // a seven-day clock must not depend on which page is open.
              const UnlinkBanner(),
              // Presence used to float here, top-centre over every screen. It
              // covered titles and buttons, interrupted whatever was being
              // read, and looked like a system alert instead of a person. It
              // now lives in each screen's own AppBar next to their name —
              // see PartnerHereAction.
              // The shared bloom when one of them warms the room. Root-level
              // so it reaches the whole screen, above the page and below the
              // lock.
              const Positioned.fill(child: WarmthOverlay()),
                    ],
                    ),
                    ),
                  ),
                  // The covers themselves sit OUTSIDE that TickerMode — a
                  // lock screen that muted its own animations would be the
                  // one thing on screen and frozen.
                  // DIRECT child of the Stack, with nothing between:
                  // LockScreen returns a Positioned.fill of its own, and a
                  // Positioned whose nearest ancestor render object is not
                  // the Stack throws "Incorrect use of ParentDataWidget" —
                  // which, as the CallPip comment above records, greys out
                  // the whole app and swallows every touch. The
                  // RepaintBoundary that used to sit here did exactly that;
                  // isolation belongs INSIDE LockScreen, the way CallPip
                  // does it.
                  if (locked) const LockScreen(),
                  // Stealth quick-cover: invisible top-right tap zone +
                  // scrim, present on every screen inside the real app.
                  const Positioned.fill(child: StealthLayer()),
                ],
              ),
            ),
          ),
        );
      },
      ),
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
