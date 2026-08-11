import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/fcm_service.dart';
import 'package:miles/core/services/session_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The owner signed a fresh account into a handset, signed back into his old
/// one, and received a Reach belonging to the NEW account inside the OLD
/// account's session. profiles.fcm_token is a device identity kept in a
/// per-user column: production held one token on two profiles in two different
/// couples, so reach-notify addressed one couple's private signal to a phone
/// signed in as the other.
///
/// The database now refuses to let one token sit on two profiles, but that
/// cannot cover a push already in flight — or a message queued behind its 24h
/// TTL — landing after the account on the handset has changed. So the receiving
/// side has to reject it too, and this is the only place that can be tested
/// without two phones.
void main() {
  const mine = 'couple-mine';
  const theirs = 'couple-theirs';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    pendingReach.value = null;
    pendingCall.value = null;
    pendingChat.value = null;
    await SessionScope.setCouple(mine);
  });

  group('a tapped notification belonging to another couple is discarded', () {
    test('reach', () {
      FcmService.routeFromPayload('reach-7|Alice|$theirs');
      expect(pendingReach.value, isNull);
    });

    test('call', () {
      FcmService.routeFromPayload('call|call-9|Alice|1|$theirs');
      expect(pendingCall.value, isNull);
    });

    test('message', () {
      FcmService.routeFromPayload('message|msg-42|$theirs');
      expect(pendingChat.value, isNull);
    });
  });

  group('the signed-in couple still gets everything', () {
    test('reach', () {
      FcmService.routeFromPayload('reach-7|Alice|$mine');
      expect(pendingReach.value?.reachId, 'reach-7');
    });

    test('call', () {
      FcmService.routeFromPayload('call|call-9|Alice|1|$mine');
      expect(pendingCall.value?.callId, 'call-9');
    });

    test('message opens chat, never the Reach overlay', () {
      FcmService.routeFromPayload('message|msg-42|$mine');
      expect(pendingChat.value, 'msg-42');
      expect(pendingReach.value, isNull);
    });
  });

  test('a payload from an older build, with no couple, still routes', () {
    // The app is sideloaded and has no update channel, so a notification posted
    // by a previous build can outlive it in the tray. Dropping those would turn
    // this guard into a silent outage.
    FcmService.routeFromPayload('reach-7|Alice');
    expect(pendingReach.value?.reachId, 'reach-7');
  });

  test('signing out leaves nothing for the next account to inherit', () async {
    FcmService.routeFromPayload('reach-7|Alice|$mine');
    expect(pendingReach.value, isNotNull);

    // pendingReach is a global that outlives a session, and the shell only
    // drains it when it mounts. Left set, the NEXT account's shell pops the
    // previous account's overlay on the first frame it builds.
    await SessionScope.setCouple(null);
    pendingReach.value = null;

    FcmService.routeFromPayload('reach-8|Alice|$mine');
    expect(pendingReach.value, isNull,
        reason: 'signed out: no couple belongs to this handset',);
  });

  test('the stored couple survives a cold start, before the session loads', () async {
    // Sign out, then hand the process a prefs store that still names the
    // couple — which is exactly the state a relaunch starts in.
    await SessionScope.setCouple(null);
    SharedPreferences.setMockInitialValues({'active_couple_id': mine});
    await SessionScope.hydrate();

    // A cold start from a tapped notification routes long before loadProfile
    // resolves. Without hydrate the live couple reads null and the guard throws
    // away the very tap that launched the app.
    FcmService.routeFromPayload('reach-7|Alice|$mine');
    expect(pendingReach.value?.reachId, 'reach-7');
  });
}
