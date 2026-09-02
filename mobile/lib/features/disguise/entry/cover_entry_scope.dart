import 'package:flutter/widgets.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';

/// What the pointer layer over a cover is doing.
enum EntryLayerMode {
  /// On the cover: matching the owner's move and the backup hold; a match
  /// runs the gate.
  watch,

  /// In the recorder: every counted touch and committed word is reported,
  /// nothing is matched.
  record,
}

/// Shared between the host (or the recorder), the pointer layer and the few
/// cover controls that commit a typed word.
///
/// A cover never learns which mode it is in and never reaches the gate: the
/// one thing it may do is hand a committed string to [feedText] from a control
/// it already has, and act on the answer.
class CoverEntryController {
  CoverEntryController({required this.mode, required this.onOpen});

  EntryLayerMode mode;

  /// The move being matched — the stored one on the cover; null in the
  /// recorder, which matches nothing.
  CoverEntryTrigger? trigger;

  /// The layer matched [trigger] or the backup hold.
  final void Function(EntrySource source) onOpen;

  /// Record-mode reports.
  void Function(TouchEvent event)? onRecordedTouch;
  void Function(String raw)? onRecordedText;

  /// A cover's commit control handing over what was typed. Only a committed
  /// string can ever count — nothing a user merely types is a door.
  ///
  /// Returns true when the cover should act as if the commit was consumed:
  /// the calculator skips the calculation, the note is not saved.
  bool feedText(String raw, {required bool commit}) {
    if (!commit) return false;
    switch (mode) {
      case EntryLayerMode.record:
        final sink = onRecordedText;
        if (sink == null) return false;
        sink(raw);
        return true;
      case EntryLayerMode.watch:
        final t = trigger;
        if (t is! TextTrigger || !t.matches(raw)) return false;
        onOpen(EntrySource.custom);
        return true;
    }
  }
}

class CoverEntryScope extends InheritedWidget {
  const CoverEntryScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final CoverEntryController controller;

  /// Null when the cover is built with no host above it (a bare widget test),
  /// in which case a commit is just a commit.
  static CoverEntryController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CoverEntryScope>()
      ?.controller;

  @override
  bool updateShouldNotify(CoverEntryScope oldWidget) =>
      controller != oldWidget.controller;
}
