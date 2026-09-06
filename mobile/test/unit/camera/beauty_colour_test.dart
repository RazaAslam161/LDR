import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/camera/beauty/beauty_engine.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';
import 'package:miles/features/chat/camera/camera_filters.dart';

/// Who owns the colour preset, and the rule that it is never two of them.
///
/// With the GPU retouch armed, the deterministic presets move into the stream
/// so the recording finally carries them. The Dart overlay and the CPU bake
/// must then stand down for those presets — apply it in both places and every
/// snap comes out twice as saturated as the viewfinder showed.
void main() {
  final screen =
      File('lib/features/chat/camera/rapid_camera_screen.dart').readAsStringSync();

  group('which presets the GPU may own', () {
    test('a matrix, with or without an overlay, is foldable', () {
      for (final id in ['none', 'noir', 'warm', 'cool', 'color_pop', 'golden', 'neon', 'glitch']) {
        final f = kCameraFilters.firstWhere((f) => f.id == id);
        expect(f.gpuFoldable, isTrue, reason: id);
      }
    });

    test('blur and grain stay on the CPU, where they already match the overlay', () {
      for (final id in ['freesia', 'retro', 'soft']) {
        final f = kCameraFilters.firstWhere((f) => f.id == id);
        expect(f.gpuFoldable, isFalse, reason: id);
      }
    });
  });

  group('one owner per path, pinned in the screen', () {
    test('the decision is a single getter', () {
      expect(screen, contains('bool get _gpuOwnsColour =>'));
      expect(screen, contains('_beautyArmed && _selectedFilter.gpuFoldable'),
          reason: 'armed AND foldable; either alone would double-apply or drop',);
    });

    test('the viewfinder overlay stands down when the GPU owns colour', () {
      expect(screen, contains('filter: _gpuOwnsColour ? kCameraFilters[0] : _selectedFilter'));
    });

    test('the bake skips colour but never skips the mirror', () {
      expect(screen, contains("(!_gpuOwnsColour && _selectedFilter.id != 'none') || mirror"),
          reason: 'the front-camera mirror is still a CPU job; only colour moved',);
      expect(screen, contains('_gpuOwnsColour ? kCameraFilters[0] : _selectedFilter'));
    });

    test('choosing a preset, arming and rebinding all re-send the colour', () {
      expect('_applyColour()'.allMatches(screen).length, greaterThanOrEqualTo(3),
          reason: 'the strip tap, the boot arm and the sheet rebind',);
    });
  });

  group('the engine payload', () {
    final calls = <MethodCall>[];
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls.clear();
      BeautyEngine.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BeautyEngine.channel, (call) async {
        calls.add(call);
        return call.method == 'arm' ? true : null;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(BeautyEngine.channel, null);
    });

    test('a preset goes across as 20 doubles plus its overlay', () async {
      await BeautyEngine.arm(const BeautySettings(enabled: true));
      calls.clear();
      final glitch = kCameraFilters.firstWhere((f) => f.id == 'glitch');
      await BeautyEngine.setColour(glitch);
      expect(calls.single.method, 'colour');
      final args = calls.single.arguments as Map;
      expect(args['on'], isTrue);
      expect((args['matrix'] as List).length, 20);
      expect(args['overlayArgb'], glitch.overlayColor!.toARGB32());
      expect(args['overlayScreen'], isA<bool>());
    });

    test('null clears with a one-key payload the engine cannot misread', () async {
      await BeautyEngine.arm(const BeautySettings(enabled: true));
      calls.clear();
      await BeautyEngine.setColour(null);
      expect(calls.single.arguments, {'on': false});
    });

    test('nothing is sent while the effect is not armed', () async {
      await BeautyEngine.setColour(kCameraFilters[1]);
      expect(calls, isEmpty,
          reason: 'disarmed, the Dart overlay and the CPU bake own colour; a '
              'stray payload would be a grade with no owner on the next arm',);
    });
  });
}
