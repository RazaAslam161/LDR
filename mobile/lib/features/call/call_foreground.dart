import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:miles/core/services/reach_notifications.dart';
import 'package:miles/features/disguise/disguise_notification.dart';

/// Keeps a call's audio alive when the app is backgrounded or the screen is off,
/// via an Android foreground service (microphone type). Started when a call
/// begins, stopped when it ends.
///
/// The notification it is required to post wears the same disguise as every
/// other notification this app raises. It used to read
/// `On call with <partner's real name>` / `Tap to return to the call`, at the
/// plugin's default VISIBILITY_PUBLIC — so for the whole of every call, and for
/// the whole 45s of a call nobody answered, an un-swipeable notification naming
/// the partner sat on the lock screen under a news app's icon. The disguise
/// guard test did not catch it because the strings were inline here rather than
/// beside the channel constants it reads.

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

/// The service types the one shared foreground service must declare at runtime.
///
/// `mediaProjection` is only ever asked for while a screen share is live.
/// Android 14+ requires a service already carrying that type before a
/// projection's virtual display is created, and it refuses a type the manifest
/// does not also declare — so this list and the manifest's
/// `android:foregroundServiceType` have to agree.
List<ForegroundServiceTypes> callServiceTypes({required bool screenSharing}) =>
    screenSharing
        ? const [
            ForegroundServiceTypes.microphone,
            ForegroundServiceTypes.mediaProjection,
          ]
        : const [ForegroundServiceTypes.microphone];

class CallForegroundService {
  CallForegroundService._();

  static bool _inited = false;

  /// Whether the live service currently carries `mediaProjection`. Tracks the
  /// projection rather than the call, so the type goes away with the share; a
  /// second share in the same call pays the restart again, which is correct —
  /// Android 15+ issues a fresh projection token every time anyway.
  static bool _screenSharing = false;

  static void _ensureInit() {
    if (_inited) return;
    _inited = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: kCallServiceChannelId,
        channelName: kCallServiceChannelName,
        channelDescription: kCallServiceChannelDesc,
        onlyAlertOnce: true,
        // The plugin defaults this to VISIBILITY_PUBLIC, which is what put the
        // partner's name on the lock screen. Every other notification this app
        // posts is already secret (reach_notifications.dart).
        visibility: NotificationVisibility.VISIBILITY_SECRET,
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

  /// [force] restarts a service that is already running, which is the only way
  /// to change its `serviceTypes` — see [_swapServiceTypes].
  static Future<void> start({bool force = false}) async {
    try {
      _ensureInit();
      if (!force && await FlutterForegroundTask.isRunningService) return;
      final style = await currentNotificationStyle();
      await FlutterForegroundTask.startService(
        serviceId: 512,
        serviceTypes: callServiceTypes(screenSharing: _screenSharing),
        notificationTitle: style.title,
        notificationText: style.body,
        // Without this the small icon falls back to the *application* icon
        // (@mipmap/ic_launcher), which is opaque edge to edge — Android masks a
        // small icon to its alpha channel, so it arrives as the solid white
        // square disguise_notification.dart already warns about, and it is the
        // News tile even on a handset wearing the Calculator cover.
        notificationIcon: NotificationIcon(metaDataName: style.iconMetaData),
        callback: callTaskCallback,
      );
    } catch (_) {
      // Background-keepalive is best-effort; never break the call over it.
    }
  }

  /// Bring `mediaProjection` into the live service's type set.
  ///
  /// Restarts the one shared service rather than updating it, because
  /// `updateService` cannot change `serviceTypes` — only `startService` takes
  /// them. The keepalive is unheld for that restart, which happens while the
  /// app is foreground (the user has just cleared the system consent dialog),
  /// where it is doing nothing anyway.
  static Future<void> addScreenShare() => _swapServiceTypes(sharing: true);

  /// Drop `mediaProjection` again once the projection is gone.
  ///
  /// The flag used to be latched for the rest of the call, so a call that had
  /// shared once kept a mediaProjection-typed foreground service running long
  /// after there was any projection to justify it — and, on a share that failed
  /// to start at all, without there ever having been one.
  static Future<void> dropScreenShare() => _swapServiceTypes(sharing: false);

  static Future<void> _swapServiceTypes({required bool sharing}) async {
    if (_screenSharing == sharing) return;
    _screenSharing = sharing;
    try {
      _ensureInit();
      if (!await FlutterForegroundTask.isRunningService) {
        await start();
        return;
      }
      await FlutterForegroundTask.stopService();
      // Wait for the stop to actually land.
      //
      // `start()` returns early when the service is still running, and
      // `stopService()` resolving does not mean Android has finished tearing
      // the service down — so the old sequence could stop the service and then
      // skip the restart, leaving a share with no mediaProjection type at all.
      // On Android 14+ that is not a degraded share, it is a refused one: the
      // platform declines to create the virtual display.
      await _awaitStopped();
      await start(force: true);
    } catch (_) {
      // Background-keepalive is best-effort; never break the call over it.
    }
  }

  /// Bounded, because someone is holding the phone and a share must not hang
  /// on a service that will not admit it has stopped. `start(force: true)`
  /// runs either way.
  static Future<void> _awaitStopped() async {
    for (var i = 0; i < 20; i++) {
      if (!await FlutterForegroundTask.isRunningService) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  static Future<void> stop() async {
    _screenSharing = false;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }
}
