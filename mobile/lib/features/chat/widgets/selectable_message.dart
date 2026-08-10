import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:miles/core/ui/theme.dart';

/// The gesture layer that turns a chat bubble into something selectable.
///
/// This exists as its own widget because the obvious version does not work.
/// Photos, videos and voice notes carry their own tap handlers deeper in the
/// tree — open the viewer, play the note — and in Flutter's gesture arena the
/// innermost recognizer wins. An `onTap` wrapped around the outside therefore
/// never fires on exactly the messages a user most wants to select, which is
/// the media the feature was asked for.
///
/// So while a selection is open the bubble's own handlers are taken out of the
/// hit test entirely. That is also the behaviour you want: tapping a photo
/// mid-selection should add it to the selection, not open it full screen.
class SelectableMessage extends StatelessWidget {
  const SelectableMessage({
    required this.selecting, required this.selected, required this.onToggle, required this.child, super.key,
  });

  /// Whether a selection is open anywhere in the conversation — not whether
  /// this particular message is in it.
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        // While selecting there is no hittable child, so say outright that
        // this detector is the target rather than leaning on the tint layer
        // underneath happening to be opaque.
        behavior: HitTestBehavior.opaque,
        onLongPress: () {
          HapticFeedback.selectionClick();
          onToggle();
        },
        onTap: selecting ? onToggle : null,
        child: ColoredBox(
          color: selected
              ? MilesColors.ember.withValues(alpha: 0.22)
              : Colors.transparent,
          child: IgnorePointer(ignoring: selecting, child: child),
        ),
      );
}
