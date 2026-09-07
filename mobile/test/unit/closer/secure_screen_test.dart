import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/diag/diag.dart';
import 'package:miles/features/closer/secure_screen.dart';

/// The first test the screenshot mechanism ever had. `resetForTest` shipped
/// with no caller; `active` flipped true before the platform answered and
/// survived a failure, so the screen-share banner could promise a flag the
/// window never got.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('miles/secure_screen');
  final calls = <MethodCall>[];
  final rows = <Map<String, Object?>>[];
  Object? fail;

  setUp(() {
    SecureScreen.resetForTest();
    ErrorReporter.resetForTest();
    ErrorReporter.insertRow = (row) async => rows.add(row);
    calls.clear();
    rows.clear();
    fail = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (fail != null) throw fail!;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('active flips only after the platform confirmed the flag', () async {
    final pending = SecureScreen.acquire();
    expect(SecureScreen.active.value, isFalse,
        reason: 'a wish is not a report',);
    await pending;
    expect(SecureScreen.active.value, isTrue);
    expect(calls.single.method, 'setSecure');
    expect(calls.single.arguments, {'enable': true});
  });

  test('a platform failure is reported and leaves active false', () async {
    fail = PlatformException(code: 'window');
    await SecureScreen.acquire();
    expect(SecureScreen.active.value, isFalse);
    expect(SecureScreen.holders, 1);
    expect(rows, isNotEmpty, reason: 'the failure must leave the handset');
    expect(rows.first['kind'], 'secure-screen');
  });

  test('the flag is refcounted: on with the first holder, off with the last',
      () async {
    await SecureScreen.acquire();
    await SecureScreen.acquire();
    expect(calls.length, 1);
    await SecureScreen.release();
    expect(SecureScreen.active.value, isTrue);
    await SecureScreen.release();
    expect(SecureScreen.active.value, isFalse);
    expect(calls.last.arguments, {'enable': false});
  });

  test('a release with no holder is a no-op', () async {
    await SecureScreen.release();
    expect(calls, isEmpty);
    expect(SecureScreen.active.value, isFalse);
  });
}
