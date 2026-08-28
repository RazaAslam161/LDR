import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/app/providers.dart';
import 'package:miles/core/app/release_gate.dart';
import 'package:miles/core/app/root_scaffold_key.dart';
import 'package:miles/core/app/router.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/crypto_core.dart';
import 'package:miles/features/reels/share_intake.dart';
import 'package:miles/core/data/partner_rewrap.dart';
import 'package:miles/core/ui/tab_dissolve.dart';
import 'package:miles/core/widgets/gilt_nav_icon.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/realtime/realtime_resume.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/services/location_service.dart';
import 'package:miles/core/services/update_service.dart';
import 'package:miles/core/widgets/escrow_prompt.dart';
import 'package:miles/core/widgets/safety_code_prompt.dart';
import 'package:miles/core/widgets/surface_panel.dart';
import 'package:miles/core/widgets/update_sheet.dart';
import 'package:miles/features/call/call_controller.dart';
import 'package:miles/features/call/pip_mode.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/features/chat/chat_draft_store.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/chat_screen.dart';
import 'package:miles/features/chat/chat_send_queue.dart';
import 'package:miles/features/chat/widgets/chat_input_bar.dart';
import 'package:miles/features/closer/closer_screen.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/disguise_service.dart';
import 'package:miles/features/home/home_screen.dart';
import 'package:miles/features/reach/reach_overlay_screen.dart';
import 'package:miles/features/reach/reach_repository.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/touch_map/touch_map_screen.dart';
import 'package:miles/main.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


/// How long away makes the screen you left the wrong one to come back to.
///
/// Tuned high on purpose. The common absence in this app is a reply gap - the
/// phone goes down mid-conversation and comes back to the same thread - and a
/// short threshold would keep taking people out of a chat they are still
/// having. Past twenty minutes the tab is no longer context, it is only where
/// they happened to be standing, and returning to Touch or Closer is a worse
/// answer than returning to Home.
const kLongAbsence = Duration(minutes: 20);

/// Whether a return after [away] should land on the default tab instead of the
/// one the user left.
///
/// [overlayActive] is the app handing focus out ON PURPOSE - a picker, the
/// biometric prompt, the in-app camera, a permission dialog. None of those is
/// the user leaving, and counting them is how attaching one photo would end on
/// the Home tab. It is the same exclusion the cover and the app lock already
/// honour (MilesApp.systemOverlayActive / MilesApp.authInProgress).
bool landsHome({required Duration away, required bool overlayActive}) =>
    !overlayActive && away >= kLongAbsence;

/// Work that landing on Home would destroy or orphan, so the landing stands
/// down and the user keeps the screen they were on.
///
/// [callLive] is global: a call survives a tab change, but the return-to-call
/// window and the PiP window are drawn OVER the shell, so moving the tab
/// underneath them is visible, pointless, and drops the user somewhere else
/// the moment they hang up.
///
/// The other three live in the Chat tab's own State, which is exactly what a
/// tab change disposes - so they only count while Chat is the tab being left.
/// Two of them are safe by construction and are honoured anyway: a draft is
/// encrypted to disk by ChatDraftStore and comes back, and ChatSendQueue
/// exists precisely so a send outlives the screen that started it. Neither
/// loses data; both would lose the user's place. [recording] is the one that
/// loses the recording itself - the AudioRecorder belongs to the input bar's
/// State and goes down with it.
bool resumeIsBusy({
  required bool callLive,
  required bool onChatTab,
  required bool recording,
  required bool draftPending,
  required bool sending,
}) =>
    callLive || (onChatTab && (recording || draftPending || sending));

/// Bottom-nav shell. Tab 0 is Home (the landing screen). The Closer tab is only
/// shown to verified adults. An app-wide listener pops the full-screen Reach
/// overlay whenever the partner reaches.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  RealtimeChannel? _reachChannel;
  ManagedSubscription? _rewrapSub;
  bool _rewrapOpen = false;
  final Set<String> _shownReach = {};
  CallState _lastCallState = CallState.idle;

  /// Which room a bar index means under the given flags.
  static String _tabIdentity(int index,
      {required bool touch, required bool closer,}) {
    if (index <= 2) return const ['home', 'chat', 'camera'][index < 0 ? 0 : index];
    if (touch && index == 3) return 'touch';
    if (closer && index == (touch ? 4 : 3)) return 'closer';
    return 'home';
  }

  /// Where a room sits under the given flags. A room that no longer exists
  /// answers Home — never a neighbouring index that now means something else.
  static int _tabIndex(String id, {required bool touch, required bool closer}) {
    switch (id) {
      case 'chat':
        return 1;
      case 'camera':
        return 2;
      case 'touch':
        return touch ? 3 : 0;
      case 'closer':
        return closer ? (touch ? 4 : 3) : 0;
      default:
        return 0;
    }
  }

  /// The Chat room's identity in [shellTabProvider].
  static const String _chatTab = 'chat';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pendingReach.addListener(_onPendingReach);
    pendingCall.addListener(_onPendingCall);
    pendingChat.addListener(_onPendingChat);
    pendingMemory.addListener(_onPendingMemory);
    realtimeResumed.addListener(_rearmAlwaysOn);
    ReleaseGate.revision.addListener(_onReleaseChanged);
    // Before the first build, not after it: deciding this in a
    // post-frame callback paints the tab they left for one frame and
    // then swaps it, which is the jump this change exists to avoid.
    _returned(fromMount: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onReady());
  }

  /// When the app last left the foreground, so a resume can tell a cover flip
  /// from a real absence.
  ///
  /// STATIC, and that is the whole of the repair below it. [MilesApp.raiseCover]
  /// swaps the router - this shell included - for the disguise cover on every
  /// real background, and both flavours ship with the disguise on. So the
  /// instance that watched the app leave is never the instance that watches it
  /// come back: as a plain field this could only ever time a picker or a PiP
  /// call, which is why the doze reconnect underneath it has never once run on
  /// the absence it was written for. It dies with the process, which is right -
  /// a cold start already lands on Home with a fresh tab provider.
  static DateTime? _leftForegroundAt;

  /// Whether that departure was the app handing focus out on purpose.
  ///
  /// Latched with the timestamp above and NOT read on the way back, which
  /// is the only way it can be true. MilesApp clears systemOverlayActive
  /// on every `resumed` (main.dart), and its observer is registered
  /// before this one because it builds the tree this lives in - so by the
  /// time a resume reaches here the flag has already been wiped and asking
  /// it would always answer 'the user left'. Asked at the moment of
  /// leaving, it answers what it is for: a picker, a permission dialog or
  /// the biometric prompt is what took the foreground, not the user.
  static bool _leftViaOverlay = false;

  /// Below this, a socket cannot have been killed by doze — Android does not
  /// freeze a process that was away for two seconds.
  static const _dozeRisk = Duration(seconds: 20);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (_leftForegroundAt == null) {
        _leftForegroundAt = DateTime.now();
        _leftViaOverlay =
            MilesApp.systemOverlayActive || MilesApp.authInProgress;
      }
      return;
    }
    _returned(fromMount: false);
  }

  /// The app is in front of the user again.
  ///
  /// Called from two places, because a return arrives in two shapes and only
  /// one of them was ever handled. With the cover DOWN - a picker, PiP, a
  /// shade peek - this shell is alive and receives `resumed`. With the cover
  /// UP, which is the ordinary background, `resumed` is delivered to a tree
  /// this shell is not part of, and the first thing it learns is its own
  /// mount. Same event, same answer, so one method serves both.
  void _returned({required bool fromMount}) {
    final left = _leftForegroundAt;
    final viaOverlay = _leftViaOverlay;
    _leftForegroundAt = null;
    _leftViaOverlay = false;
    // A cold start, or a resume with no recorded absence. Nothing to decide.
    if (left == null) return;
    final away = DateTime.now().difference(left);

    // Short-circuited on purpose: [_resumeIsBusy] reads four providers and
    // singletons, and a brief absence - the common case by a wide margin -
    // must not pay for a question it is never going to ask.
    final home =
        landsHome(away: away, overlayActive: viaOverlay) && !_resumeIsBusy;

    // Resetting the socket closes EVERY channel on it. A trace showed all five
    // going down together on a resume — messages, receipts, mood_burst,
    // presence and, worst, the call signalling channel:
    //
    //   rt_channel_join messages   status:closed
    //   signal_subscribe           status:closed
    //
    // An offer arriving inside that window is missed outright, and this app
    // resumes constantly because the disguise cover flips it. So the reset
    // happens only when the app was away long enough for doze to have actually
    // killed the socket. A cover flip, a picker or a shade peek leaves it alone.
    Diag.record(DiagArea.app, 'rt_resume_decision', fields: {
      'away_ms': away.inMilliseconds,
      'reconnected': away >= _dozeRisk,
      'overlay': viaOverlay,
      'home': home,
      'mount': fromMount,
    });
    if (away >= _dozeRisk) _reconnectRealtime();
    if (home) _landHome(publish: !fromMount);
  }

  /// Reads the live state behind [resumeIsBusy]. See it for why each of these
  /// counts, and why three of them are scoped to the Chat tab.
  bool get _resumeIsBusy {
    final call = ref.read(callControllerProvider).state;
    final couple = ref.read(sessionProvider).couple;
    return resumeIsBusy(
      callLive: PipMode.active.value ||
          call == CallState.calling ||
          call == CallState.ringing ||
          call == CallState.connected,
      onChatTab: ref.read(shellTabProvider) == _chatTab,
      recording: ChatInputBar.recording.value,
      draftPending:
          couple != null && (ChatDraftStore.peek(couple.id) ?? '').isNotEmpty,
      // Only what is actually moving. A send that has already FAILED sits in
      // the queue with a retry affordance until the user deals with it, and
      // reading that as busy would pin someone to the Chat tab for good.
      sending: ChatSendQueue.instance.pending
              .any((s) => s.status == SendStatus.sending) ||
          ChatSendQueue.instance.pendingText
              .any((s) => s.status == SendStatus.sending),
    );
  }

  /// Select Home, without lying about where the user is standing.
  ///
  /// The literal 0 is deliberate: it is the only index that names the same
  /// room for every account. Touch and Closer are conditional destinations, so
  /// 3 is Closer for one user and Touch for another, and index 2 (Camera) has
  /// no body at all.
  ///
  /// Nothing is popped. A route the user pushed - the call screen, the vault,
  /// a capsule - stays exactly where it is; they simply find Home underneath
  /// it on the way out, and the observer republishes the tab itself on that
  /// pop.
  void _landHome({required bool publish}) {
    final tabs = ref.read(shellTabProvider.notifier);
    if (tabs.state == 'home') return;
    tabs.state = 'home';
    // Published only when the shell is genuinely what the user is looking at.
    // Announcing 'Home' from underneath a pushed route tells the partner the
    // wrong room, and the observer's dedupe then keeps that lie past the pop.
    // On the mount path there is nothing to publish from - an InheritedWidget
    // cannot be read during initState - and _onReady's own publishActiveTab
    // covers it a frame later, from the tab this has already corrected.
    if (publish && GoRouter.of(context).state.uri.path == '/app') {
      presenceRouteObserver?.publishActiveTab();
    }
  }

  /// Realtime sockets die silently during Android doze (no close event), so the
  /// client keeps "connected" and stops delivering reaches/presence until a full
  /// restart. On resume we force a fresh socket + re-subscribe the reach channel
  /// so Reach (and presence/map, which rejoin on the new socket) recover.
  Future<void> _reconnectRealtime() async {
    // Android doze can kill the socket silently; force a clean reconnect. When
    // it re-opens, onOpen → realtimeResumed → _rearmAlwaysOn + every per-screen
    // subscription rejoins. (Re-subscribing synchronously here raced the
    // still-closing socket and left the channels joined-but-dead — the cause of
    // chat not auto-rendering and the online/offline flicker.)
    try {
      await SupabaseService.client.realtime.disconnect();
      // connect() is marked @internal by realtime_client, so a package upgrade
      // may remove it without a breaking-change note and this reconnect would
      // stop compiling — or worse, be "fixed" by deleting it. Kept because the
      // pair is what actually revives the socket after doze, and every feature
      // that reads as broken in the field (presence, receipts, call
      // signalling) rides on that socket. Replacing it needs a two-phone test,
      // not a refactor.
      // ignore: invalid_use_of_internal_member
      await SupabaseService.client.realtime.connect();
    } catch (_) {}
  }

  /// Re-arm the always-on realtime (reach / call / presence) whenever the
  /// socket (re)connects — driven by realtimeResumed (the onOpen fan-out), so
  /// it runs AFTER the socket is open, never against a closing one.
  Future<void> _rearmAlwaysOn() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    // Pattern A: remove the old reach channel (awaited) before re-subscribing so
    // a reconnect never leaves a duplicate-topic 'reach:<id>' channel dead.
    final old = _reachChannel;
    _reachChannel = null;
    if (old != null) {
      try {
        await SupabaseService.client.removeChannel(old);
      } catch (_) {}
    }
    _reachChannel = ReachRepository.subscribe(couple.id, _onReach);
    unawaited(ref.read(callControllerProvider).reconnect());
    ref.read(sessionProvider.notifier).reconnectPresence();
    // A share into a still-running app arrives as onNewIntent → resume.
    unawaited(_drainSharedLink());
  }

  /// True when the ceremony route is already on top — the stateless guard the
  /// per-State [_rewrapOpen] cannot be: every cover flip disposes this State
  /// and resets the flag, so without this check each remount re-offered the
  /// ceremony on top of itself.
  bool _rewrapRouteUp() =>
      GoRouter.of(context)
          .routerDelegate.currentConfiguration.uri.path ==
      '/rewrap';

  /// A link shared from another app while the queue screen was not mounted
  /// used to evaporate — ShareIntake drained only inside that screen, and
  /// nothing routed there on ACTION_SEND. Drain here, hand the URL across,
  /// and carry the user to the list where it lands.
  Future<void> _drainSharedLink() async {
    final url = ShareIntake.firstUrl(await ShareIntake.take());
    if (url == null || !mounted) return;
    ShareIntake.handedOff = url;
    if (!_rewrapRouteUp()) context.push('/app/watch-list');
  }

  Future<void> _resumeOwnRewrap() async {
    if (_rewrapOpen || _rewrapRouteUp()) return;
    if (await CryptoCore.heldRequest() == null) return;
    // Re-checked after the await: this and _offerRewrap fire unawaited side by
    // side, and both passing the entry guard before either sets the flag ends
    // with two rewrap screens claiming over each other.
    if (!mounted || _rewrapOpen || _rewrapRouteUp()) return;
    _rewrapOpen = true;
    await context.push('/rewrap');
    _rewrapOpen = false;
  }

  /// Opens the rewrap screen when the partner has a live request waiting.
  ///
  /// Not a push notification, and none should be added: an FCM payload saying
  /// "your partner is reinstalling" hands the event to Google, and the voice
  /// call the ceremony already requires IS the notification.
  Future<void> _offerRewrap(String coupleId) async {
    if (_rewrapOpen || _rewrapRouteUp()) return;
    final RewrapRequest? req;
    try {
      req = await PartnerRewrap.pending(coupleId);
    } catch (_) {
      // Offline, or a socket that delivered before the session had a token.
      // Swallowed rather than thrown: this runs unawaited from a realtime
      // callback, the subscription fires again on the next change, and the
      // request stands for ten minutes.
      return;
    }
    if (req == null || !mounted || _rewrapOpen || _rewrapRouteUp()) return;
    _rewrapOpen = true;
    await context.push('/rewrap');
    _rewrapOpen = false;
  }

  void _onReady() {
    // First: a shared link is the user's own stated intent for this launch.
    unawaited(_drainSharedLink());
    unawaited(_maybeOfferUpdate());
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    // Foreground realtime path — works whether or not push is configured.
    _reachChannel = ReachRepository.subscribe(couple.id, _onReach);
    // Register this device for push now that we're past login + pairing.
    FcmService.registerToken();
    // A push may have been tapped before the listener attached.
    _onPendingReach();
    _onPendingCall();
    // Accounts signed in before key escrow existed have no sealed copy of their
    // key, and no reason to ever sign out and acquire one. They lose every
    // encrypted memory on their next reinstall. Asked once, here, because this
    // is the first point past login and pairing.
    unawaited(EscrowPrompt.maybeShow(context));
    // Covers shipped before App Lock was a precondition of wearing one. A
    // phone that applied one back then and upgraded now carries a way back
    // with no lock behind it — the picker refuses that combination today, so
    // this is the standing repair for installs that predate the rule. Asked
    // every session until the lock is on or the cover is off, because an
    // unguarded door is a disguise that opens for whoever holds the phone.
    unawaited(_nudgeLockForCover());
    // The pin catches every partner-key change after the first sight; the one
    // thing it cannot catch is a directory that lied AT the first sight, and
    // only the two people can — by reading the same twenty digits to each
    // other. Last of the launch prompts, and it stands down when one of the
    // others is already on screen: a key that was never compared is a smaller
    // loss than a key that was never backed up, or a cover with no lock behind
    // it. Asked once per key, then never again until the key changes.
    unawaited(
      SafetyCodePrompt.maybeShow(
        context,
        partnerId: ref.read(sessionProvider).partner?.id,
      ),
    );
    // The other half is setting up a new phone and cannot open anything the two
    // of them wrote. This device still holds the key, so it is the only thing
    // that can give it back — and a request lives ten minutes, which is why it
    // is looked for here rather than waited for somewhere quieter.
    _rewrapSub = ManagedSubscription.start(
      () => RealtimeService.coupleTable(
        channelName: 'rewrap:${couple.id}',
        table: 'partner_rewrap_requests',
        coupleId: couple.id,
        onChange: (_) => unawaited(_offerRewrap(couple.id)),
      ),
    );
    unawaited(_offerRewrap(couple.id));
    // The other direction of the same ceremony: THIS phone asked and then the
    // process died. The session persists, so a relaunch never crosses sign-in
    // and its held-check — this is the only place a restarted asker passes
    // through. pending() cannot surface it (it filters own requests out), so
    // the hold is the one record that this phone owes the screen a code.
    unawaited(_resumeOwnRewrap());
    _onPendingChat();
    // The shell mounts on '/app', which the observer answers from the selected
    // tab — but that happens before this state exists on a cold start.
    presenceRouteObserver?.publishActiveTab();
    _firstRunPrompts(couple.id);
  }

  /// The repair half of the picker's App-Lock precondition: a cover applied
  /// by an older build, still worn, with no lock enrolled.
  /// Asked ONCE, and never again if the answer was no.
  ///
  /// "Not now" used to just pop the dialog and persist nothing, so this fired
  /// on every shell mount — and the disguise backgrounds the app, so Android
  /// kills the process routinely and the shell mounts constantly. The result
  /// was a prompt that reappeared for the rest of the install's life, which
  /// reads as a bug rather than advice.
  ///
  /// App Lock is the user's call. A recommendation that cannot be declined is
  /// not a recommendation, and one that re-asks forever teaches people to
  /// dismiss dialogs without reading them — which is the opposite of what a
  /// security prompt is for.
  static const _lockNudgeDeclinedKey = 'miles_lock_nudge_declined_v1';

  Future<void> _nudgeLockForCover() async {
    final profile = await DisguiseService.current();
    if (profile.cover == DisguiseCover.none) return;
    if (await AppLock.isEnabled()) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_lockNudgeDeclinedKey) ?? false) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your cover needs App Lock'),
        content: const Text(
          'Your cover keeps a way back into this app — that is your '
          'guarantee against being locked out. App Lock is what makes that '
          'way back safe: with it on, it lands on your lock, not the app.\n\n'
          'Turn on App Lock in Settings, or switch the cover off.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              // Remembered, so this is genuinely "not now" and not "ask me
              // again in ninety seconds". Turning App Lock on later clears
              // nothing — the enabled check above short-circuits first.
              unawaited(prefs.setBool(_lockNudgeDeclinedKey, true));
              Navigator.pop(ctx);
            },
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ctx.go('/app/settings');
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  /// A resume re-read the gate and the answer moved. Offer the update from the
  /// screen the user is already on — without this the re-check updates statics
  /// nothing consults again until the next cold start, which is the whole bug.
  void _onReleaseChanged() {
    if (!mounted) return;
    unawaited(_maybeOfferUpdate());
  }

  static int _offeredForBuild = 0;

  /// A newer sideload build exists — offered once PER BUILD, and only when no
  /// more important prompt (escrow, first-run permissions) already holds the
  /// screen. The Settings row carries the same action for any launch this skips,
  /// so nothing is lost by yielding.
  ///
  /// Keyed on the build rather than a bool because the gate is re-read on
  /// resume: a long-lived process that declined build N must still be offered
  /// N+1, and a plain "offered once per process" latch swallowed it forever.
  Future<void> _maybeOfferUpdate() async {
    if (_offeredForBuild == ReleaseGate.latestBuild ||
        !UpdateService.available) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    // A more important prompt (escrow, first-run permissions) is holding the
    // screen — yield without spending the once-a-session offer, since Settings
    // is the only other path and a later launch should still try.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _offeredForBuild = ReleaseGate.latestBuild;
    await showUpdateSheet(context);
  }

  /// The one-time onboarding prompts, in sequence.
  ///
  /// Fired in parallel they land on top of one another and the user dismisses
  /// whichever is in front — which is how a permission ask gets refused without
  /// ever being read. The location one is last because it is the only one that
  /// leads to a system dialog we cannot draw over.
  Future<void> _firstRunPrompts(String coupleId) async {
    // The cover question is NOT here any more, and does not run from anywhere
    // else either — the picker is Settings-only. Restoring a first-run offer
    // is the play channel's account-strike scenario (build.gradle.kts,
    // DISGUISE_ENABLED condition 1), so it stays out on every channel.
    final partnerName =
        ref.read(sessionProvider).partner?.displayName ?? 'your partner';
    // One-time, dismissible full-screen-alert prompt (Android 14+).
    await FsiPermission.promptIfNeeded(context, partnerName);
    if (!mounted) return;
    // Location is not requested at startup any more, so this is where a fresh
    // install is asked — explained first, and followed by the sharing mode so
    // that granting it actually shows the partner something.
    await LocationService.onboard(context, coupleId, partnerName);
  }

  void _onReach(ReachEvent e) {
    final uid = SupabaseService.currentUserId;
    if (e.isMine(uid) || !e.isActive) return;
    final partnerName =
        ref.read(sessionProvider).partner?.displayName ?? 'Your partner';
    _showReach(e.id, partnerName);
  }

  /// From a foreground push or a tapped notification (FcmService.pendingReach).
  void _onPendingReach() {
    final tap = pendingReach.value;
    if (tap == null) return;
    pendingReach.value = null;
    final name = tap.fromName.isNotEmpty ? tap.fromName : 'Your partner';
    _showReach(tap.reachId, name);
  }

  /// An incoming call delivered by FCM (full-screen ring / tapped notification /
  /// cold start). Hand it to the CallController to fetch the offer + ring.
  void _onPendingCall() {
    final tap = pendingCall.value;
    if (tap == null) return;
    pendingCall.value = null;
    ref
        .read(callControllerProvider)
        .handlePendingCall(tap.callId, tap.fromName, tap.video);
  }

  /// A tapped message notification. Selects the Chat tab, which is also what
  /// acks delivery — the catch-up fetch there is the only ack path a push has.
  void _onPendingChat() {
    if (pendingChat.value == null) return;
    pendingChat.value = null;
    if (!mounted) return;
    ref.read(shellTabProvider.notifier).state = _chatTab;
    presenceRouteObserver?.publishActiveTab();
  }

  /// A tapped memory notification. Opens Memory Threads directly rather than
  /// selecting the Closer tab: the feature is the last tile in the grid, behind
  /// its own PIN, and "we told you, now go and find it" is most of why nine
  /// proposals were never opened.
  ///
  /// The gate still stands — this pushes the route, and the route asks for the
  /// PIN exactly as it does when reached by hand.
  void _onPendingMemory() {
    final tap = pendingMemory.value;
    if (tap == null) return;
    pendingMemory.value = null;
    // A proposal that merely ARRIVED while the app is open is not a reason to
    // move anyone; the Closer tile's count is how that one surfaces.
    if (!tap.fromTap || !mounted) return;
    context.push('/app/closer/memory-threads');
  }

  /// Single entry point for the overlay — de-duped by reach id so the realtime
  /// and push paths never double-show the same Reach.
  void _showReach(String reachId, String partnerName) {
    if (reachId.isNotEmpty && _shownReach.contains(reachId)) return;
    if (reachId.isNotEmpty) _shownReach.add(reachId);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            ReachOverlayScreen(partnerName: partnerName, eventId: reachId),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pendingReach.removeListener(_onPendingReach);
    pendingCall.removeListener(_onPendingCall);
    pendingChat.removeListener(_onPendingChat);
    pendingMemory.removeListener(_onPendingMemory);
    realtimeResumed.removeListener(_rearmAlwaysOn);
    ReleaseGate.revision.removeListener(_onReleaseChanged);
    _rewrapSub?.dispose();
    final ch = _reachChannel;
    _reachChannel = null;
    if (ch != null) SupabaseService.client.removeChannel(ch);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Pop the call screen up on an incoming ring or an outgoing call. (For a
    // ChangeNotifierProvider, prev==next is the same instance, so we track the
    // last state ourselves to detect the inactive -> active transition.)
    //
    // [_lastCallState] is per-State-instance, so it CANNOT be the only guard:
    // the disguise cover swaps the whole MaterialApp, and the rebuilt shell
    // starts again at `idle` while the GoRouter — a plain Provider that is
    // never invalidated — still has /call on its stack. Every cover cycle then
    // read as a fresh inactive -> active transition and pushed another copy,
    // which is why a screen share that outlived a trip to another app ended up
    // drawing itself several times over. [pushCallRoute] asks the router what
    // is actually on top, which no remount can lie about.
    ref.listen(callControllerProvider, (_, c) {
      final now = c.state;
      bool active(CallState s) =>
          s == CallState.ringing ||
          s == CallState.calling ||
          s == CallState.connected;
      final fire = active(now) && !active(_lastCallState);
      _lastCallState = now;
      if (fire && context.mounted) pushCallRoute(GoRouter.of(context));
    });

    // Only rebuild the shell when these specific flags flip — NOT on every
    // partner presence / mood / typing tick (all of which flow through
    // sessionProvider and were rebuilding the whole tab scaffold + active screen).
    final isAdult =
        ref.watch(sessionProvider.select((s) => s.profile?.isAdult ?? false));
    final isModest =
        ref.watch(sessionProvider.select((s) => s.couple?.modestMode ?? true));

    final showCloser = isAdult;
    // Touch rides the same switch as Closer rather than being always-on. Body
    // photos with a heat meter are the same register as the rest of that
    // module, and it was the one intimate surface reachable without either
    // partner having agreed to reveal any of it.
    final showTouch = isAdult && !isModest;

    // The provider stores the room's IDENTITY, so a flag flip needs no remap
    // and no State-held baseline (a baseline died with the shell on every
    // cover cycle, resurrecting the teleport it existed to stop). The one
    // case to handle: the room the user is standing in ceases to exist —
    // resolve to Home for THIS frame, persist it, and TELL THE PARTNER
    // (every other tab write pairs with publishActiveTab; the first remap
    // fix forgot the publish and left a live join-offer into a dead room).
    var identity = ref.watch(shellTabProvider);
    if ((identity == 'touch' && !showTouch) ||
        (identity == 'closer' && !showCloser)) {
      identity = 'home';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(shellTabProvider.notifier).state = 'home';
        if (GoRouter.of(context).state.uri.path == '/app') {
          presenceRouteObserver?.publishActiveTab();
        }
      });
    }
    final index = _tabIndex(identity, touch: showTouch, closer: showCloser);
    // Bottom-nav bodies (Home, Chat, [Touch], [Closer]). The Camera tab is a
    // full-screen PUSH inserted at nav index 2 — it has no body, so nav indices
    // map past it. Built rather than sliced: Touch sits in the MIDDLE, so
    // dropping it with sublist would have silently shifted Closer's index.
    final bodies = <Widget>[
      const HomeScreen(),
      const ChatScreen(),
      if (showTouch) const TouchMapScreen(),
      if (showCloser) const CloserScreen(),
    ];
    const cameraTab = 2;
    final destCount = bodies.length + 1; // + the Camera tab
    final selected = index.clamp(0, destCount - 1);
    final bodyIndex = (selected < cameraTab ? selected : selected - 1)
        .clamp(0, bodies.length - 1);

    return Scaffold(
      key: rootScaffoldKey,
      drawer: const AppDrawer(),
      body: Column(
        children: [
          Expanded(
            child: TabDissolve(index: bodyIndex, child: bodies[bodyIndex]),
          ),
        ],
      ),
      bottomNavigationBar: SurfaceNavBar(
        child: NavigationBar(
          backgroundColor: Colors.transparent,
          selectedIndex: selected,
          onDestinationSelected: (i) {
            if (i == cameraTab) {
              _openCamera(); // a push — keep the current tab selected
              return;
            }
            ref.read(shellTabProvider.notifier).state =
                _tabIdentity(i, touch: showTouch, closer: showCloser);
            // A tab change is a setState, not a navigation, so nothing else
            // can tell the partner the user has moved rooms.
            presenceRouteObserver?.publishActiveTab();
          },
          // GiltSelect: each destination hands both its faces to GiltNavIcon,
          // which cross-fades them, lifts 2px and blooms the one-shot gilt
          // ring. The NavigationBar's own icon swap is bypassed (no
          // selectedIcon) so the fade owns the change; the theme's indicator
          // pill is transparent for the same reason.
          destinations: [
            NavigationDestination(
              icon: GiltNavIcon(
                icon: const Icon(Icons.home_outlined),
                selectedIcon: const Icon(Icons.home),
                selected: selected == 0,
              ),
              label: 'Home',
            ),
            NavigationDestination(
              icon: GiltNavIcon(
                icon: const Icon(Icons.chat_bubble_outline),
                selectedIcon: const Icon(Icons.chat_bubble),
                selected: selected == 1,
              ),
              label: 'Chat',
            ),
            // The camera is a push, never a selected tab, so it keeps its
            // plain icon pair — a selection animation on it would promise a
            // room the user is not in.
            const NavigationDestination(
              icon: Icon(Icons.camera_alt_outlined),
              selectedIcon: Icon(Icons.camera_alt),
              label: 'Camera',
            ),
            if (showTouch)
              NavigationDestination(
                icon: GiltNavIcon(
                  icon: const Icon(Icons.touch_app_outlined),
                  selectedIcon: const Icon(Icons.touch_app),
                  selected: selected == 3,
                ),
                label: 'Touch',
              ),
            if (showCloser)
              NavigationDestination(
                icon: GiltNavIcon(
                  icon: const Icon(Icons.lock_outline),
                  selectedIcon: Icon(
                    isModest ? Icons.lock : Icons.lock_open,
                    color: const Color(0xFFEF6F58),
                  ),
                  selected: selected == (showTouch ? 4 : 3),
                ),
                label: 'Closer',
              ),
          ],
        ),
      ),
    );
  }

  /// Opens the in-app rapid camera (the centre nav button) — a full-screen push
  /// that drops the snap into chat.
  void _openCamera() {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    context.push('/app/rapid-camera', extra: {
      'coupleId': couple.id,
      'myUid': SupabaseService.currentUserId ?? '',
    },);
  }
}
