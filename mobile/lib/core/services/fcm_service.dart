import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:miles/core/data/supabase_repository.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/core/diag/diag_event.dart';
import 'package:miles/core/services/fsi_permission.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:miles/features/chat/chat_broadcast_service.dart';
import 'package:miles/features/chat/chat_receipts.dart';
import 'package:miles/features/chat/message_preview_port.dart';
import 'package:miles/main.dart';

/// A Reach that should surface the in-app overlay (from a foreground push or a
/// tapped notification). The AppShell listens to [pendingReach] and shows the
/// overlay, de-duping by [reachId] against its realtime listener.
class ReachTap {
  const ReachTap(this.reachId, this.fromName);
  final String reachId;
  final String fromName;
}

final ValueNotifier<ReachTap?> pendingReach = ValueNotifier<ReachTap?>(null);

/// An incoming call to ring — from a foreground push, a tapped full-screen
/// notification, or a cold start. The AppShell hands this to the CallController.
class CallTap {
  const CallTap(this.callId, this.fromName, this.video,
      {required this.fromTap,});
  final String callId;
  final String fromName;
  final bool video;

  /// Whether the user actually chose to come here.
  ///
  /// True only when this ring arrived through a notification the user tapped,
  /// or a cold start from one. False when it arrived on [FcmService._onForeground]
  /// — which fires with the app already running, having posted no notification
  /// at all, so nothing was shown and nothing was tapped.
  ///
  /// [CoverGate] refuses to open on a ring that was not tapped. Without that,
  /// a partner pressing Call replaces the cover the user is looking at with the
  /// call screen — their avatar and real name — within a frame, unprompted;
  /// and with an app lock enrolled it raises a biometric prompt the user did
  /// not initiate. The app sits on the cover after every background
  /// (main.dart:269-271), so that is the ordinary case, not the rare one.
  final bool fromTap;
}

final ValueNotifier<CallTap?> pendingCall = ValueNotifier<CallTap?>(null);

/// A tapped message notification: the AppShell selects the Chat tab. Holds the
/// message id only so a trace can tie the tap back to the push that caused it.
final ValueNotifier<String?> pendingChat = ValueNotifier<String?>(null);

/// A memory proposal arrived, or a memory notification was tapped.
///
/// [fromTap] separates the two, and the distinction is the whole point: a tap
/// means open the thread, while a push landing in the foreground means only
/// "refresh the count". Without the flag, a proposal arriving while she is
/// mid-sentence in chat would throw her onto another screen — the same mistake
/// [CallTap] carries this field to avoid.
class MemoryTap {
  const MemoryTap(this.memoryId, {required this.fromTap});
  final String memoryId;
  final bool fromTap;
}

final ValueNotifier<MemoryTap?> pendingMemory = ValueNotifier<MemoryTap?>(null);

/// The four beats of the unlinking ritual, as reach-notify labels them.
///
/// One predicate rather than four literals in three places: the tap router
/// below defaults to REACH for anything it does not recognise, so a beat that
/// is missed here does not go quiet — it rings the loudest alert in the app,
/// during a breakup, with somebody else's id in the reach slot.
bool _isUnlink(Object? type) =>
    type == 'unlink' ||
    type == 'unlink_lastcall' ||
    type == 'unlink_relinked' ||
    type == 'unlink_ended';

/// An unlink push, foreground or tapped. Carries nothing but the fact —
/// the ceremony row itself is fetched over RLS; AppShell routes to /unlink.
final ValueNotifier<bool?> pendingUnlink = ValueNotifier<bool?>(null);

/// Wires Firebase Messaging: permission, token lifecycle, the local-notification
/// channel, and the foreground / tapped-notification handlers.
///
/// Token storage goes through [SupabaseRepository] (never the widget layer).
class FcmService {
  FcmService._();

  static final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();

  /// Call once in main() after Firebase.initializeApp. Sets up channels +
  /// handlers. Token registration is separate (registerToken, after login).
  static Future<void> init() async {
    // Before any routing below: a cold start from a tapped notification runs
    // long before the session resolves, and the couple guard has to know which
    // account this handset was last signed in as or it would discard the very
    // tap that launched the app.
    await SessionScope.hydrate();
    // Open the channel the FCM background isolate uses to hand a delivery ack
    // to this isolate. Registered before any handler below, because a push can
    // arrive the moment the process exists and the background isolate decides
    // whether the app is alive by whether this port answers.
    DeliveryAckPort.listen();
    // Lets the background handler hand a push to this isolate, which has the
    // couple key and can turn a count into the actual message text.
    MessagePreviewPort.listen();
    await _fln.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onLocalTap,
    );
    final android = _fln.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(buildReachChannel());
    await android?.createNotificationChannel(buildCareChannel());
    await android?.createNotificationChannel(buildCallChannel());
    // Retires the "Ongoing call / Shown while a call is in progress" channel,
    // which stayed listed in Android's notification settings on any handset
    // that had ever placed a call. The service posts to kCallServiceChannelId
    // now; this id must never be created again or the old name comes back.
    await android?.deleteNotificationChannel(
      channelId: kLegacyCallServiceChannelId,
    );
    // Same reasoning, different leak: this one was named 'Messages', described
    // as 'New messages', and sat in the notification settings of an app whose
    // launcher says Weather. Anyone scrolling that list found a messenger
    // without ever opening it. Replaced by kMsgChannelId ('Updates'); a channel
    // cannot be renamed, so this id must never be created again.
    await android?.deleteNotificationChannel(
      channelId: kLegacyMsgChannelId,
    );
    await android?.createNotificationChannel(buildQuietChannel());

    // Cold start via a tapped notification of any kind.
    final launch = await _fln.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      routeFromPayload(launch!.notificationResponse?.payload);
    }

    FirebaseMessaging.onMessage.listen(_onForeground);
    FirebaseMessaging.onMessageOpenedApp.listen(_onOpenedApp);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _onOpenedApp(initial);

    // Mirror the FSI permission so the background isolate can read it.
    await FsiPermission.refreshCache();
  }

  /// Android 13+/iOS notification permission prompt.
  static Future<void> requestPermission() async {
    await FirebaseMessaging.instance.requestPermission();
  }

  static bool _refreshHooked = false;

  /// After login + pairing AND on every app resume: ask permission, fetch the
  /// token (retrying if Google Play Services isn't ready yet), and re-save it.
  ///
  /// Re-saving on each foreground is the important part: the notify functions
  /// null a recipient's token server-side when FCM reports it UNREGISTERED (a
  /// stale token after a reinstall/GMS hiccup), which silently stops their
  /// pushes. Re-registering on the next launch/resume self-heals that.
  static Future<void> registerToken() async {
    // Piggy-backs the one hook that already runs on every resume
    // (main.dart:364). A push can be dropped, throttled by FCM, or never sent
    // at all — coming back to the app is the moment to settle what this
    // handset already holds, and it is emphatically not a moment anyone read
    // anything: the app resumes onto the News cover.
    unawaited(
      ChatReceiptRepository.ackHighestDelivered(trigger: 'app_resume'),
    );
    await requestPermission();
    String? token;
    for (var i = 0; i < 4 && token == null; i++) {
      try {
        token = await FirebaseMessaging.instance.getToken();
      } catch (e) {
        debugPrint('FcmService getToken attempt ${i + 1} failed: $e');
      }
      if (token == null) await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (token != null) await _save(token);
    if (!_refreshHooked) {
      _refreshHooked = true;
      FirebaseMessaging.instance.onTokenRefresh.listen(_save);
    }
  }

  static Future<void> _save(String token) async {
    try {
      await SupabaseRepository.setFcmToken(token);
    } catch (e) {
      debugPrint('FcmService._save failed: $e');
    }
  }

  /// On sign-out: unbind this handset from the account leaving it.
  ///
  /// All three parts matter. The server row must stop naming this token, or
  /// reach-notify keeps pushing that couple's private signals here. The FCM
  /// token itself is deleted so the next account gets a fresh one rather than
  /// inheriting the last one. And the pending notifiers are globals that
  /// outlive a session — a Reach that arrived while the cover was up sits in
  /// [pendingReach] until a shell mounts to drain it, which after a sign-in as
  /// someone else means the next account's shell pops the previous account's
  /// overlay.
  ///
  /// Must run while still authenticated: setFcmToken writes as the current
  /// user, so calling this after signOut() silently does nothing.
  /// Removes the conversation's unread entry from the shade.
  ///
  /// Keyed on the couple, matching showMessageNotification's id, because there
  /// is exactly ONE entry per conversation rather than one per message — the
  /// thing that made a disguised app buzz like a messenger.
  static Future<void> clearMessageNotification(String coupleId) async {
    if (coupleId.isEmpty) return;
    try {
      await _fln.cancel(id: coupleId.hashCode & 0x7fffffff);
    } catch (e, st) {
      // Not fatal: the count is already cleared, so the worst case is a stale
      // entry the owner can swipe. Reported rather than swallowed so a platform
      // channel that starts failing here is visible from the server.
      ErrorReporter.report(e, st, kind: 'notify');
    }
  }

  static Future<void> forgetDevice() async {
    pendingReach.value = null;
    pendingCall.value = null;
    pendingChat.value = null;
    await SessionScope.setCouple(null);
    try {
      await SupabaseRepository.setFcmToken(null);
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      debugPrint('FcmService.forgetDevice failed: $e');
    }
  }

  // ── delivery receipts ──────────────────────────────────────────────────────

  /// Say "this handset has it" for a message push, without saying it was read.
  ///
  /// The payload carries `message_id` and not `seq` (reach-notify/index.ts:246),
  /// so the seq is resolved server-side; the `seq` branch is here for the day
  /// the edge function starts sending one, and costs an old client nothing.
  static Future<void> _ackDelivery(
    Map<String, dynamic> data, {
    required String trigger,
  }) async {
    final seq = int.tryParse('${data['seq']}') ?? 0;
    if (seq > 0) {
      await ChatReceiptRepository.ackDelivered(seq, trigger: trigger);
    } else {
      ChatReceiptRepository.ackHighestDeliveredSoon(trigger: trigger);
    }
  }

  // ── handlers ───────────────────────────────────────────────────────────────
  static void _onForeground(RemoteMessage m) {
    if (!_forThisSession(m)) return;
    final type = m.data['type'];
    if (type == 'call') {
      // fromTap: false — onMessage fires with the app already running and posts
      // no notification, so nothing was shown and nothing was tapped. The shell
      // still rings when the real app is visible; CoverGate refuses to open on
      // this, so a partner cannot replace the cover the user is looking at.
      pendingCall.value = CallTap(
        (m.data['call_id'] as String?) ?? '',
        (m.data['from_name'] as String?) ?? 'Your partner',
        (m.data['video'] as String?) == 'true',
        fromTap: false,
      );
      // The cover is up, so the ring has no visible surface at all unless one
      // is posted here — the background isolate never ran.
      if (!MilesApp.showRealApp.value) {
        showCallNotification(
          plugin: _fln,
          callId: (m.data['call_id'] as String?) ?? '',
          fromName: (m.data['from_name'] as String?) ?? '',
          coupleId: (m.data['couple_id'] as String?) ?? '',
          video: (m.data['video'] as String?) == 'true',
          fullScreen: false,
        );
      }
      return;
    }
    if (type == 'care') {
      // Foreground reminder: post the (blank, secret) notification directly.
      showCareNotification(
        plugin: _fln,
        nudgeId: (m.data['nudge_id'] as String?) ?? '',
        coupleId: (m.data['couple_id'] as String?) ?? '',
      );
      return;
    }
    // `msg_sync` is the delivery wake the trigger actually sends; `message` is
    // the older name, kept because a push already queued under it must still
    // ack rather than be dropped on the floor. Both are silent in the
    // foreground — the chat's own realtime subscription is what shows a message
    // to someone looking at it.
    if (type == 'msg_sync' || type == 'message') {
      Diag.record(DiagArea.receipt, 'push_msg_received',
          corr: m.data['message_id'] as String?,
          fields: {
            'app_state': 'foreground',
            // The chat registers its live broadcast channel while mounted, so
            // this is the same fact the fast path depends on.
            'chat_mounted': ChatBroadcastService.active != null,
            'has_message_id': m.data['message_id'] != null,
          },);
      // This device HAS the message — say so, whether or not anything is on
      // screen. `onMessage` fires for a foregrounded app, which includes the
      // app sitting on the News cover with no chat mounted; that used to reach
      // here and return, leaving the sender on one grey tick.
      //
      // Delivered, never read. Nobody has looked at anything: the app may be
      // behind the cover, behind the biometric lock, or on another tab.
      unawaited(_ackDelivery(m.data, trigger: 'push_fg'));
      // No notification. The chat's realtime subscription already delivers the
      // message when it is mounted, and the owner does not want message
      // banners — the push is here to move the tick, nothing else.
      return;
    }
    if (type == 'memory') {
      // A proposal is not urgent enough to interrupt, but it must not be lost
      // either — a foregrounded app that swallows it leaves the partner in
      // exactly the state all nine production rows are in. So the tray gets it
      // (discoverable later, wearing the disguise) and the notifier lets a
      // mounted Closer grid update its count now.
      showMemoryNotification(
        plugin: _fln,
        memoryId: (m.data['memory_id'] as String?) ?? '',
        coupleId: (m.data['couple_id'] as String?) ?? '',
      );
      pendingMemory.value =
          MemoryTap((m.data['memory_id'] as String?) ?? '', fromTap: false);
      return;
    }
    if (_isUnlink(type)) {
      // Foreground: realtime usually gets there first, and while the ritual
      // holds the screen UnlinkScreen is refetching on its own. This covers
      // the race where the push wins — and all four beats, because a kind
      // without a branch here falls through to the Reach overlay below.
      pendingUnlink.value = true;
      return;
    }
    if (type != 'reach') return;
    // Foreground: surface the in-app overlay. AppShell de-dupes by reach_id so
    // this and the Supabase realtime listener never double-show.
    pendingReach.value = ReachTap(
      (m.data['reach_id'] as String?) ?? '',
      (m.data['from_name'] as String?) ?? 'Your partner',
    );
  }

  static void _onOpenedApp(RemoteMessage m) {
    if (!_forThisSession(m)) return;
    final type = m.data['type'];
    if (type == 'call') {
      pendingCall.value = CallTap(
        (m.data['call_id'] as String?) ?? '',
        (m.data['from_name'] as String?) ?? 'Your partner',
        (m.data['video'] as String?) == 'true',
        fromTap: true,
      );
      return;
    }
    if (type == 'memory') {
      pendingMemory.value =
          MemoryTap((m.data['memory_id'] as String?) ?? '', fromTap: true);
      return;
    }
    if (_isUnlink(type)) {
      pendingUnlink.value = true;
      return;
    }
    if (type != 'reach') return;
    pendingReach.value = ReachTap(
      (m.data['reach_id'] as String?) ?? '',
      (m.data['from_name'] as String?) ?? 'Your partner',
    );
  }

  /// Whether a push belongs to the couple signed in on this handset.
  ///
  /// The token is the device's, not the account's, so FCM will happily deliver
  /// a couple's Reach to a phone that has since been signed into a different
  /// account — which is how one couple's private signal surfaced inside
  /// another's session. Nothing else in the delivery path checks this.
  static bool _forThisSession(RemoteMessage m) => SessionScope.allows(
        m.data['couple_id'] as String?,
        SessionScope.coupleId,
      );

  static void _onLocalTap(NotificationResponse r) => routeFromPayload(r.payload);

  /// Routes a tapped local notification by the payload its poster wrote in
  /// reach_notifications.dart. Both halves live on the same device, so this is
  /// the only place they have to agree — and the only place a test can reach.
  @visibleForTesting
  static void routeFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    final parts = payload.split('|');
    final tag = parts.isNotEmpty ? parts[0] : '';
    // Each payload ends with the couple it was posted for, so a notification
    // still sitting in the tray from a previous account cannot be tapped into
    // the current one. A payload without it predates this and is let through,
    // the same way a push without couple_id is.
    String? field(int i) => parts.length > i ? parts[i] : null;
    if (tag == 'call') {
      // call|callId|fromName|video|coupleId
      if (!SessionScope.allows(field(4), SessionScope.coupleId)) return;
      pendingCall.value = CallTap(
        parts.length > 1 ? parts[1] : '',
        parts.length > 2 ? parts[2] : 'Your partner',
        !(parts.length > 3) || parts[3] == '1',
        fromTap: true,
      );
      return;
    }
    if (tag == 'message') {
      // message|messageId|coupleId — opens the Chat tab. Falling through to the
      // Reach branch below is what made a plain text message pop the
      // full-screen Reach overlay, on every build that posts a message
      // notification.
      if (!SessionScope.allows(field(2), SessionScope.coupleId)) return;
      pendingChat.value = parts.length > 1 ? parts[1] : '';
      return;
    }
    if (tag == 'care') return; // care taps just open the app
    // ritual|ritualId|coupleId — the ritual has already been delivered by
    // arriving. Like care, the tap just opens the app; falling through would
    // ring the full-screen Reach overlay with a ritual id in the reach slot.
    if (tag == 'ritual') return;
    if (tag == 'memory') {
      // memory|memoryId|coupleId — opens the thread. Without this branch it
      // falls through to the Reach default below and pops the full-screen
      // overlay with a memory id in the reach slot, which is what the comment
      // there warns about.
      if (!SessionScope.allows(field(2), SessionScope.coupleId)) return;
      pendingMemory.value =
          MemoryTap(parts.length > 1 ? parts[1] : '', fromTap: true);
      return;
    }
    if (tag == 'unlink') {
      // unlink|coupleId — opens the ceremony screen, never the Reach overlay.
      if (!SessionScope.allows(parts.length > 1 ? parts[1] : null,
          SessionScope.coupleId,)) {
        return;
      }
      pendingUnlink.value = true;
      return;
    }
    // Untagged by construction: the Reach payload is 'reachId|fromName|coupleId'
    // and predates every tagged kind. So this is a default branch that ASSUMES
    // reach — any new kind must get its own branch above it, or it lands here
    // and shows the overlay with a garbage id.
    if (!SessionScope.allows(field(2), SessionScope.coupleId)) return;
    pendingReach.value = ReachTap(
      tag,
      parts.length > 1 ? parts[1] : 'Your partner',
    );
  }
}
