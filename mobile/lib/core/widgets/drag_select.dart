import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Press and slide to select a run of items — the gesture every phone gallery
/// has and this app did not.
///
/// Selecting eleven photographs cost eleven long presses, and there was no way
/// at all to select a range. This is the mechanism behind "with a swipe, not
/// tap by tap", and it is one widget rather than three because the hard parts
/// — arbitrating against the scroll view, mapping a finger to an item, and
/// scrolling while the finger is still down — are identical on a gallery grid,
/// a vault grid and a conversation.
///
/// **Long press, then slide.** Deliberately not a bare drag: a bare drag is
/// how the list scrolls, and taking it would leave a selecting user unable to
/// reach anything off-screen. The arena settles it correctly with no help —
/// `LongPressGestureRecognizer` wins when the finger holds still for
/// `kLongPressTimeout`, and the Scrollable's drag wins the moment it moves
/// first. Once the long press is accepted, `postAcceptSlopTolerance` is null,
/// so the finger may travel any distance and the updates keep arriving.
///
/// **One recognizer, at the top.** A per-cell `onLongPress` is deeper in the
/// tree and wins the arena against this one, so a screen adopting this must
/// take the long press OFF its cells and let [onAnchor] be where selection
/// starts. Two recognizers for one gesture is a coin toss decided by hit-test
/// order.
///
/// **Ranges, not toggles.** [onExtend] reports the whole span from the anchor
/// to the item under the finger on every move, so sliding back over a cell
/// un-selects it. The caller re-derives from the selection it held when the
/// drag began, which makes the gesture idempotent and reversible; toggling
/// per-cell-crossed instead is what makes hand-rolled versions of this flicker
/// and stick.
class DragSelect extends StatefulWidget {
  const DragSelect({
    required this.child,
    required this.onAnchor,
    required this.onExtend,
    required this.onEnd,
    this.scroll,
    this.enabled = true,
    super.key,
  });

  final Widget child;

  /// The long press landed on the item at this index. The caller enters
  /// selection mode, snapshots what was selected, and decides from the anchor's
  /// own state whether this drag is adding or removing.
  final void Function(int index) onAnchor;

  /// The finger is over `extent`; the caller should hold exactly the inclusive
  /// span between it and `anchor`, applied to the snapshot it took in
  /// [onAnchor].
  final void Function(int anchor, int extent) onExtend;

  /// The finger came up. The snapshot can be dropped.
  final VoidCallback onEnd;

  /// The scrollable this wraps, so the selection can run past the screen. A
  /// drag-select that stops at the last visible row is a drag-select that
  /// cannot select a hundred photographs, which is the case it exists for.
  final ScrollController? scroll;

  /// False supplies NO recognizer at all, leaving whatever the cells do with
  /// the gesture untouched. Chat uses this: outside a selection its long press
  /// belongs to the reaction bar, and a recognizer up here would race it.
  final bool enabled;

  @override
  State<DragSelect> createState() => _DragSelectState();
}

class _DragSelectState extends State<DragSelect>
    with SingleTickerProviderStateMixin {
  final GlobalKey _fieldKey = GlobalKey();

  Ticker? _ticker;
  int? _anchor;
  int? _extent;
  Offset? _pointer;

  /// How close to an edge the finger has to be before the list starts moving.
  static const _edgeBand = 84.0;

  /// Logical pixels per frame at the very edge. ~14 at 60fps is a brisk but
  /// followable scroll; faster and the user overshoots the row they wanted.
  static const _maxStep = 14.0;

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  RenderBox? get _field {
    final box = _fieldKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box : null;
  }

  /// The item index under [global], or null if the finger is over a gap, a
  /// header, or nothing at all.
  ///
  /// A hit test rather than arithmetic over the grid delegate. Arithmetic has
  /// to be told the cross-axis count, the spacings and the padding, and it
  /// silently returns the wrong row the day any of those change or a header
  /// appears above the grid — which is exactly what a sectioned vault does.
  /// The tree already knows where every cell is.
  int? _indexAt(Offset global) {
    final box = _field;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    if (!(local.dx >= 0 &&
        local.dy >= 0 &&
        local.dx <= box.size.width &&
        local.dy <= box.size.height)) {
      return null;
    }
    final result = BoxHitTestResult();
    box.hitTest(result, position: local);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData) {
        final data = target.metaData;
        if (data is DragSelectTag) return data.index;
      }
    }
    return null;
  }

  void _onStart(LongPressStartDetails d) {
    final i = _indexAt(d.globalPosition);
    if (i == null) return;
    unawaited(HapticFeedback.mediumImpact());
    _anchor = i;
    _extent = i;
    _pointer = d.globalPosition;
    widget.onAnchor(i);
    _ticker ??= createTicker(_autoScroll);
    if (!_ticker!.isActive) _ticker!.start();
  }

  void _onMove(LongPressMoveUpdateDetails d) {
    _pointer = d.globalPosition;
    _extendTo(d.globalPosition);
  }

  void _extendTo(Offset global) {
    final anchor = _anchor;
    if (anchor == null) return;
    final i = _indexAt(global);
    // Null means the finger is between cells or over a header. Holding the
    // last good extent is right: releasing the selection because a fingertip
    // crossed a 2px gutter is the jitter that makes this feel broken.
    if (i == null || i == _extent) return;
    _extent = i;
    unawaited(HapticFeedback.selectionClick());
    widget.onExtend(anchor, i);
  }

  void _finish() {
    if (_anchor == null) return;
    _anchor = null;
    _extent = null;
    _pointer = null;
    if (_ticker?.isActive ?? false) _ticker!.stop();
    widget.onEnd();
  }

  /// Runs the list under the finger while the finger stays near an edge.
  void _autoScroll(Duration _) {
    final pointer = _pointer;
    final controller = widget.scroll;
    final box = _field;
    if (pointer == null || controller == null || box == null) return;
    if (!controller.hasClients) return;
    final dy = box.globalToLocal(pointer).dy;
    final height = box.size.height;
    // Signed depth into whichever band the finger is in, 0..1.
    final double depth;
    if (dy < _edgeBand) {
      depth = -(1 - (dy / _edgeBand).clamp(0.0, 1.0));
    } else if (dy > height - _edgeBand) {
      depth = 1 - ((height - dy) / _edgeBand).clamp(0.0, 1.0);
    } else {
      return;
    }
    final position = controller.position;
    final target = (position.pixels + depth * _maxStep)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return;
    controller.jumpTo(target);
    // The rows under the finger changed without the finger moving, so the span
    // has to be recomputed from the same point.
    _extendTo(pointer);
  }

  @override
  Widget build(BuildContext context) {
    final field = KeyedSubtree(key: _fieldKey, child: widget.child);
    if (!widget.enabled) return field;
    return RawGestureDetector(
      // deferToChild: this must not become the hit target itself, or the cells
      // below stop receiving their own taps.
      behavior: HitTestBehavior.deferToChild,
      gestures: <Type, GestureRecognizerFactory>{
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
          () => LongPressGestureRecognizer(debugOwner: this),
          (r) => r
            ..onLongPressStart = _onStart
            ..onLongPressMoveUpdate = _onMove
            ..onLongPressEnd = ((_) => _finish())
            ..onLongPressCancel = _finish,
        ),
      },
      child: field,
    );
  }
}

/// Marks one selectable cell with its index, for [DragSelect] to hit-test.
///
/// `MetaData` rather than a key or a callback: the finger has to be resolved to
/// an item from a bare screen coordinate, and the hit-test path is the only
/// answer that stays correct when the layout changes.
class DragSelectItem extends StatelessWidget {
  const DragSelectItem({
    required this.index,
    required this.child,
    super.key,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => MetaData(
        metaData: DragSelectTag(index),
        // Opaque so the whole cell answers, including the parts of it that
        // paint nothing. Children are still hit first and still get their own
        // taps — opaque only adds this node to the path when they do not.
        behavior: HitTestBehavior.opaque,
        child: child,
      );
}

/// What [DragSelectItem] hangs on a cell and [DragSelect] reads back.
@immutable
class DragSelectTag {
  const DragSelectTag(this.index);
  final int index;
}

/// The inclusive span between two indices, in ascending order.
///
/// Its own function so the three screens cannot each get the reversed-drag case
/// wrong in their own way.
Iterable<int> dragSelectSpan(int anchor, int extent) sync* {
  final lo = anchor < extent ? anchor : extent;
  final hi = anchor < extent ? extent : anchor;
  for (var i = lo; i <= hi; i++) {
    yield i;
  }
}
