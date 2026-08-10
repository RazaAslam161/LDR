import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:miles/core/services/reach_notifications.dart';

/// Keeps a call's audio alive when the app is backgrounded or the screen is off,
/// via an Android foreground service (microphone type) with an ongoing
/// "On call" notification. Started when a call begins, stopped when it ends.

@pragma('vm:entry-point')
void callTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_CallTaskHandler());
}

/// Minimal handler — the service just needs to exist to keep the process alive;
/// the actual WebRTC audio runs in the main isolate.
class _CallTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

class CallForegroundService {
  CallForegroundService._();

  static bool _inited = false;

  static void _ensureInit() {
    if (_inited) return;
    _inited = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'call_service',
        channelName: kCallServiceChannelName,
        channelDescription: kCallServiceChannelDesc,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> start(String peerName) async {
    try {
      _ensureInit();
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: 512,
        serviceTypes: const [ForegroundServiceTypes.microphone],
        notificationTitle: 'On call with $peerName',
        notificationText: 'Tap to return to the call',
        callback: callTaskCallback,
      );
    } catch (_) {
      // Background-keepalive is best-effort; never break the call over it.
    }
  }

  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }
}
