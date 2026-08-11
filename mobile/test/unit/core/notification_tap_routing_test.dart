import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/services/fcm_service.dart';

/// The tap router had one branch per kind and then a default that assumed
/// reach. A chat message posts 'message|<id>', matched nothing, and fell into
/// that default — so tapping a message notification opened the full-screen
/// Reach overlay with the literal string 'message' as its reach id. The push
/// worked, FCM worked, the notification worked; only the last hop was wrong.
///
/// Nothing else covers this. The payloads are written in reach_notifications
/// and read back here on the same device, so no server-side check can see a
/// mismatch, and a wrong branch is still perfectly valid Dart.
void main() {
  setUp(() {
    pendingReach.value = null;
    pendingCall.value = null;
    pendingChat.value = null;
  });

  test('a tapped message notification opens chat, not the Reach overlay', () {
    FcmService.routeFromPayload('message|msg-42');

    expect(pendingChat.value, 'msg-42');
    expect(pendingReach.value, isNull);
    expect(pendingCall.value, isNull);
  });

  test('a tapped Reach notification still shows the overlay', () {
    FcmService.routeFromPayload('reach-7|Alice');

    expect(pendingReach.value?.reachId, 'reach-7');
    expect(pendingReach.value?.fromName, 'Alice');
    expect(pendingChat.value, isNull);
  });

  test('a tapped call notification rings', () {
    FcmService.routeFromPayload('call|call-9|Bob|1');

    expect(pendingCall.value?.callId, 'call-9');
    expect(pendingCall.value?.video, isTrue);
    expect(pendingReach.value, isNull);
  });

  test('a tapped care reminder just opens the app', () {
    FcmService.routeFromPayload('care|nudge-3');

    expect(pendingReach.value, isNull);
    expect(pendingChat.value, isNull);
    expect(pendingCall.value, isNull);
  });
}
