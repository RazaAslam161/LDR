import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';

/// The retouch model, and specifically the boundary where Dart hands numbers to
/// a GPU it cannot see.
///
/// Every assertion here is a defect that would otherwise surface only on a
/// handset: a malformed preset becomes a NaN in a shader uniform, a stray Color
/// in the payload becomes a silent StandardMessageCodec failure, and an unknown
/// shade id becomes black lipstick.
void main() {
  group('defaults', () {
    test('ships off, and the fast capture path survives it', () {
      // rapid_camera_screen skips decode/re-encode entirely when nothing is
      // selected. On by default would put every first-run user through a
      // processing pass they never asked for.
      const s = BeautySettings();
      expect(s.enabled, isFalse);
      // amount is a TRIM, not a halving. It shipped at 0.5, which multiplied
      // every axis by a half on top of the skin mask; a "Natural" preset
      // landed as a ~9% blend and read as nothing happening on a real face.
      expect(s.amount, 1);
      expect(s.reshape.isIdentity, isTrue);
      expect(s.makeup.isEmpty, isTrue);
    });

    test('detail defaults to the middle, not to zero', () {
      // Detail is the counterweight that stops a strong smooth reading as
      // plastic. Defaulting it to 0 makes the very first slider drag look bad.
      expect(const RetouchParams().detail, 0.5);
    });
  });

  group('presets', () {
    test('index 0 is the identity, as kCameraFilters states for its own', () {
      expect(kBeautyPresets.first.id, 'off');
      expect(kBeautyPresets.first.settings.enabled, isFalse);
    });

    test('ids are unique and labels are non-empty', () {
      final ids = kBeautyPresets.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate preset id');
      for (final p in kBeautyPresets) {
        expect(p.label.trim(), isNotEmpty, reason: '${p.id} has no label');
      }
    });

    test('every preset value is in range', () {
      // A malformed preset does not throw — it reaches a shader as an
      // out-of-range uniform and warps a face inside out.
      for (final p in kBeautyPresets) {
        final s = p.settings;
        expect(s.amount, inInclusiveRange(0.0, 1.0), reason: p.id);
        for (final v in [
          s.retouch.smooth,
          s.retouch.tone,
          s.retouch.brighten,
          s.retouch.detail,
        ]) {
          expect(v, inInclusiveRange(0.0, 1.0), reason: p.id);
        }
        for (final v in [
          s.reshape.jaw,
          s.reshape.chin,
          s.reshape.eyes,
          s.reshape.nose,
        ]) {
          expect(v, inInclusiveRange(-1.0, 1.0), reason: p.id);
        }
      }
    });

    test('every preset shade id exists in the palette', () {
      for (final p in kBeautyPresets) {
        for (final layer in [
          p.settings.makeup.lips,
          p.settings.makeup.blush,
          p.settings.makeup.brows,
          p.settings.makeup.eyeshadow,
        ]) {
          if (layer.shadeId != null) {
            expect(kMakeupShades.containsKey(layer.shadeId), isTrue,
                reason: '${p.id} names a shade the palette does not ship',);
          }
        }
      }
    });

    test('a preset id round-trips, so the UI can name what it is showing', () {
      for (final p in kBeautyPresets) {
        expect(p.settings.presetId, p.id, reason: p.id);
      }
    });
  });

  group('the channel payload', () {
    test('disabled sends exactly one key', () {
      // The off command must not depend on the engine reading a flag it might
      // ignore.
      expect(const BeautySettings().toChannelMap(), {'enabled': false});
    });

    test('carries only primitives StandardMessageCodec can encode', () {
      final map = kBeautyPresets.last.settings.toChannelMap();
      for (final e in map.entries) {
        expect(e.value is num || e.value is bool, isTrue,
            reason: '${e.key} is ${e.value.runtimeType}, which cannot cross '
                'the channel cleanly',);
      }
    });

    test('amount is pre-multiplied in Dart, so the engine holds no policy', () {
      const s = BeautySettings(
        enabled: true,
        amount: 0.5,
        retouch: RetouchParams(smooth: 0.8),
      );
      expect(s.toChannelMap()['smooth'], closeTo(0.4, 1e-9));
    });

    test('amount 0 zeroes every axis but stays enabled', () {
      const s = BeautySettings(
        enabled: true,
        amount: 0,
        retouch: RetouchParams(smooth: 1),
        reshape: ReshapeParams(jaw: 1),
      );
      final m = s.toChannelMap();
      expect(m['enabled'], isTrue);
      expect(m['smooth'], 0.0);
      expect(m['jaw'], 0.0);
    });

    test('detail is NOT scaled by amount', () {
      // Scaling the counterweight with the effect makes a light touch
      // plasticky, which is backwards.
      const s = BeautySettings(
        enabled: true,
        amount: 0.2,
        retouch: RetouchParams(detail: 0.8),
      );
      expect(s.toChannelMap()['detail'], closeTo(0.8, 1e-9));
    });

    test('an unknown shade paints nothing, never black', () {
      const layer = MakeupLayer(shadeId: 'lips.doesnotexist', intensity: 1);
      expect(layer.effectiveIntensity, 0.0);
      expect(layer.argb, isNull);
      const s = BeautySettings(
        enabled: true,
        makeup: MakeupParams(lips: layer),
      );
      expect(s.toChannelMap()['lipsAmount'], 0.0);
      expect(s.toChannelMap()['lipsArgb'], 0);
    });

    test('the key set is the native contract and does not drift silently', () {
      // A rename here fails in CI rather than as a dead slider on a handset.
      expect(
        kBeautyPresets[1].settings.toChannelMap().keys.toSet(),
        {
          'enabled',
          'smooth',
          'tone',
          'brighten',
          'detail',
          'jaw',
          'chin',
          'eyes',
          'nose',
          'lipsArgb',
          'lipsAmount',
          'blushArgb',
          'blushAmount',
          'browsArgb',
          'browsAmount',
          'eyeshadowArgb',
          'eyeshadowAmount',
        },
      );
    });
  });

  group('persistence shape', () {
    test('json round-trips without folding amount in', () {
      const s = BeautySettings(
        enabled: true,
        amount: 0.5,
        presetId: 'natural',
        retouch: RetouchParams(smooth: 0.8, detail: 0.3),
        reshape: ReshapeParams(jaw: -0.4),
        makeup: MakeupParams(
          lips: MakeupLayer(shadeId: 'lips.rose', intensity: 0.6),
        ),
      );
      final back = BeautySettings.fromJson(s.toJson());
      // Storing the channel payload instead would bake amount into every axis
      // and drift a little further on every save.
      expect(back.retouch.smooth, 0.8);
      expect(back, s);
    });

    test('out-of-range stored numbers clamp instead of reaching a shader', () {
      final s = BeautySettings.fromJson({
        'enabled': true,
        'amount': 9.0,
        'smooth': -3.0,
        'jaw': 40.0,
      });
      expect(s.amount, 1.0);
      expect(s.retouch.smooth, 0.0);
      expect(s.reshape.jaw, 1.0);
    });

    test('a preset this build no longer ships degrades to Custom', () {
      final s = BeautySettings.fromJson({'presetId': 'retired_look'});
      expect(s.presetId, isNull);
    });

    test('garbage types fall back rather than throw', () {
      final s = BeautySettings.fromJson({
        'enabled': 'yes',
        'amount': 'lots',
        'lips': 'red',
      });
      expect(s.enabled, isFalse);
      expect(s.amount, 1);
      expect(s.makeup.lips.shadeId, isNull);
    });
  });

  group('copyWith', () {
    test('changing one axis leaves the others identical', () {
      const s = BeautySettings(
        retouch: RetouchParams(smooth: 0.5),
        reshape: ReshapeParams(jaw: 0.3),
      );
      final n = s.copyWith(amount: 0.9);
      expect(n.retouch, s.retouch);
      expect(n.reshape, s.reshape);
      expect(n.amount, 0.9);
    });

    test('clearPreset is how a moved slider becomes Custom', () {
      const s = BeautySettings(presetId: 'natural');
      expect(s.copyWith(clearPreset: true).presetId, isNull);
    });
  });
}
