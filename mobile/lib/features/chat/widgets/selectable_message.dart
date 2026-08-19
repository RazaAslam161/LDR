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
    required this.selecting, required this.selected, required this.onToggle, required this.child, this.onLongPressAt, super.key,
  });

  /// Whether a selection is open anywhere in the conversation — not whether
  /// this particular message is in it.
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final Widget child;

  /// Where this row sits on screen, reported on the long press that STARTS a
  /// selection — the one the reaction bar hangs off.
  ///
  /// Long press was already taken by selection, and it is the gesture the
  /// reaction bar wants. Rather than pick a winner, this does what WhatsApp
  /// does: the first long press selects the message AND opens the bar. A long
  /// press with a selection already open only extends it — a user building a
  /// batch to delete is not choosing an emoji, and a bar over every added
  /// message would be in the way of the very gesture they are repeating.
  final void Function(Rect anchor)? onLongPressAt;

  @override
  Widget build(BuildContext context) => GestureDetector(
        // While selecting there is no hittable child, so say outright that
        // this detector is the target rather than leaning on the tint layer
        // underneath happening to be opaque.
        behavior: HitTestBehavior.opaque,
        onLongPress: () {
          final opensBar = !selecting && onLongPressAt != null;
          // The firmer tap belongs to the affordance that opens something.
          // Extending a selection keeps the lighter one it has always had.
          opensBar
              ? HapticFeedback.mediumImpact()
              : HapticFeedback.selectionClick();
          onToggle();
          if (!opensBar) return;
          // Measured at the moment of the press, from this row's own element,
          // so the bar is anchored to where the message actually is rather
          // than to where a scroll offset says it should be.
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return;
          onLongPressAt!(box.localToGlobal(Offset.zero) & box.size);
        },
        onTap: selecting ? onToggle : null,
        child: ColoredBox(
          color: selected
              ? MilesColors.tint(MilesColors.ember, 0.22,
                  over: MilesColors.night,)
              : Colors.transparent,
          child: IgnorePointer(ignoring: selecting, child: child),
        ),
      );
}
