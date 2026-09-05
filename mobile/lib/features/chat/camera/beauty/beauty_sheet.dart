import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/camera/beauty/beauty_settings.dart';

/// The one retouch control, shared by the camera and Settings.
///
/// A preset replaces the whole look; the amount slider scales it. Every change
/// is handed to [onChanged] immediately so the caller can apply it live —
/// persisting is the caller's job, once, when this future completes, so a
/// slider drag does not write SharedPreferences sixty times a second.
Future<void> showBeautySheet(
  BuildContext context, {
  required BeautySettings current,
  required ValueChanged<BeautySettings> onChanged,
}) {
  var s = current;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheet) {
        void set(BeautySettings next) {
          s = next;
          setSheet(() {});
          onChanged(next);
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  title: const Text('Retouch'),
                  subtitle: const Text(
                    'Skin, shape and colour on your face — in the preview, '
                    'the photo and the video alike.',
                  ),
                  value: s.enabled,
                  activeThumbColor: MilesColors.ember,
                  onChanged: (v) => set(v ? _enabled(s) : s.copyWith(enabled: false)),
                ),
                if (s.enabled) ...[
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final p in kBeautyPresets)
                          if (p.id != 'off')
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(p.label),
                                selected: s.presetId == p.id,
                                selectedColor: MilesColors.ember.withValues(alpha: 0.25),
                                onSelected: (_) => set(p.settings),
                              ),
                            ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Text('Amount'),
                        Expanded(
                          child: Slider(
                            value: s.amount,
                            activeColor: MilesColors.ember,
                            onChanged: (v) => set(s.copyWith(amount: v)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Turning the switch on from a look that does nothing would show nothing, so
/// an identity look becomes Natural; an authored look is simply re-enabled.
BeautySettings _enabled(BeautySettings s) {
  final identity = s.retouch == const RetouchParams() &&
      s.reshape.isIdentity &&
      s.makeup.isEmpty;
  if (identity) {
    return kBeautyPresets.firstWhere((p) => p.id == 'natural').settings;
  }
  return s.copyWith(enabled: true);
}
