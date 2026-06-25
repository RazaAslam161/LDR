import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

/// Rich, distinct vibration patterns for the Touch feature — far more tactile
/// than the stock light/medium impacts. Each touch type feels different, and
/// the strength rises with the shared "warmth". Honest caveat: this is the
/// phone's vibration motor (whole-device) — it can't target a body part.
class TouchHaptics {
  TouchHaptics._();

  static bool _can = false;
  static bool _amp = false;
  static bool _checked = false;

  static Future<void> _ensure() async {
    if (_checked) return;
    _checked = true;
    try {
      _can = (await Vibration.hasVibrator()) == true;
      _amp = (await Vibration.hasAmplitudeControl()) == true;
    } catch (_) {
      _can = false;
    }
  }

  static int _amp255(int base, double heat) =>
      (base + heat * 70).round().clamp(1, 255);

  /// Felt by the person whose body was just touched.
  static Future<void> feel(String type, double heat) async {
    await _ensure();
    if (!_can) {
      HapticFeedback.mediumImpact(); // graceful fallback
      return;
    }
    try {
      switch (type) {
        case 'kiss':
          // A quick double peck.
          await Vibration.vibrate(
            pattern: [0, 55, 65, 80],
            intensities: _amp
                ? [0, _amp255(150, heat), 0, _amp255(210, heat)]
                : const [],
          );
        case 'hug':
          // A long, warm envelope.
          await Vibration.vibrate(
            duration: 460,
            amplitude: _amp ? _amp255(150, heat) : -1,
          );
        case 'caress':
          // A gentle, lingering stroke.
          await Vibration.vibrate(
            duration: 150,
            amplitude: _amp ? _amp255(95, heat) : -1,
          );
        default: // glow
          await Vibration.vibrate(
            duration: 70,
            amplitude: _amp ? _amp255(120, heat) : -1,
          );
      }
    } catch (_) {
      HapticFeedback.mediumImpact();
    }
  }

  /// A light confirmation for the person doing the touching.
  static void touchTick() => HapticFeedback.selectionClick();
}
