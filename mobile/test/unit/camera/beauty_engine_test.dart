import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/camera/beauty/beauty_engine.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';

/// The channel contract, with the native side replaced by a recorder.
///
/// What is pinned: the payload that crosses is `toChannelMap()` and nothing
/// else; a disabled look never arms; an unsupported device leaves the engine
/// disarmed and does not throw into the camera's boot.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  Object? armReply = true;

  setUp(() {
    calls.clear();
    armReply = true;
    BeautyEngine.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BeautyEngine.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'arm':
          return armReply;
        case 'status':
          return <Object?, Object?>{'armed': true, 'faceTracking': false};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BeautyEngine.channel, null);
  });

  const look = BeautySettings(
    enabled: true,
    amount: 0.5,
    retouch: RetouchParams(smooth: 0.8),
  );

  test('arm sends exactly the channel payload and reports native\'s answer',
      () async {
    expect(await BeautyEngine.arm(look), isTrue);
    expect(BeautyEngine.armed, isTrue);
    expect(calls.single.method, 'arm');
    expect(calls.single.arguments, look.toChannelMap());
  });

  test('a disabled look never arms; it disarms', () async {
    expect(await BeautyEngine.arm(const BeautySettings()), isFalse);
    expect(calls.where((c) => c.method == 'arm'), isEmpty);
    expect(BeautyEngine.armed, isFalse);
  });

  test('an unsupported device leaves the engine disarmed', () async {
    armReply = false;
    expect(await BeautyEngine.arm(look), isFalse);
    expect(BeautyEngine.armed, isFalse);
  });

  test('update is skipped when not armed, sent when armed', () async {
    await BeautyEngine.update(look);
    expect(calls, isEmpty);
    await BeautyEngine.arm(look);
    await BeautyEngine.update(look.copyWith(amount: 1));
    expect(calls.last.method, 'update');
    expect(calls.last.arguments, look.copyWith(amount: 1).toChannelMap());
  });

  test('disarm is sent once and is idempotent', () async {
    await BeautyEngine.arm(look);
    await BeautyEngine.disarm();
    await BeautyEngine.disarm();
    expect(calls.where((c) => c.method == 'disarm').length, 1);
    expect(BeautyEngine.armed, isFalse);
  });

  test('a native error does not throw into the caller', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BeautyEngine.channel, (call) async {
      throw PlatformException(code: 'gl', message: 'no context');
    });
    expect(await BeautyEngine.arm(look), isFalse);
    expect(BeautyEngine.armed, isFalse);
  });

  test('no plugin at all (other hosts) is simply false', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(BeautyEngine.channel, null);
    expect(await BeautyEngine.arm(look), isFalse);
    expect(await BeautyEngine.faceTracking(), isFalse);
  });

  test('faceTracking reads the status map', () async {
    expect(await BeautyEngine.faceTracking(), isFalse);
    expect(calls.single.method, 'status');
  });
}
