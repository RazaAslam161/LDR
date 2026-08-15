import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/call/call_foreground.dart';

void main() {
  group('callServiceTypes', () {
    test('a plain call declares microphone only', () {
      expect(
        callServiceTypes(screenSharing: false),
        [ForegroundServiceTypes.microphone],
      );
    });

    // The manifest's android:foregroundServiceType is a ceiling, not a
    // description: a runtime type missing from it throws
    // MissingForegroundServiceTypeException, and the permission without the
    // type throws SecurityException. Both spellings have to stay in step.
    test('a screen share adds mediaProjection without dropping the mic', () {
      final types = callServiceTypes(screenSharing: true);
      expect(types, contains(ForegroundServiceTypes.mediaProjection));
      expect(types, contains(ForegroundServiceTypes.microphone));
    });
  });
}
