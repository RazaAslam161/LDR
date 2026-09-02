import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/entry/cover_entry_scope.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';

/// A pointer that moved further than this is a drag, not a tap or a hold.
const kEntrySlop = 18.0;

/// Two fingers may drift this far and still be holding still.
/// Derived from [kCoverRecoveryHoldSeconds], never a standalone number: a
/// resting finger drifts further the longer it rests, so a tolerance tuned for
/// one duration quietly becomes an impossible gesture at a longer one. Four
/// logical pixels per second of hold — 24 at the original five seconds, 40 at
/// ten — holds the difficulty roughly constant while staying far below any
/// deliberate movement, which travels hundreds.
const kBackupSlop = 4.0 * kCoverRecoveryHoldSeconds;

/// Touches that begin inside this band along the safe box's edges are not
/// counted: thumbs rest there, and Android's own edge gestures cancel there.
const kEdgeBand = 24.0;

/// The layer's default time source, shared with the recorder so both measure
/// a hold the same way.
int wallClockMs() => DateTime.now().millisecondsSinceEpoch;

class _Pointer {
  _Pointer({required this.down, required this.downMs});

  final Offset down;
  final int downMs;
  double maxDist = 0;

  /// Set the moment a second finger joins: nothing this pointer does after
  /// that is a step of a move.
  bool multi = false;
}

/// The one place any door is watched for.
///
/// A raw [Listener], never a gesture recogniser: it receives every pointer
/// event on its subtree regardless of who wins the gesture arena, so it never
/// claims a touch, never delays one, and the cover underneath keeps scrolling,
/// rippling and typing as if nothing were there. What it does with the events
/// depends on [CoverEntryController.mode]: on the cover it matches the owner's
/// move and the backup hold; in the recorder it reports what it saw.
///
/// It paints nothing, sounds nothing, and counts nothing across attempts. A
/// miss is a miss, and the buffer forgets it.
class EntryTriggerLayer extends StatefulWidget {
  const EntryTriggerLayer({
    required this.controller,
    required this.child,
    this.nowMs = wallClockMs,
    super.key,
  });

  final CoverEntryController controller;
  final Widget child;

  /// Wall-clock milliseconds. Injectable so a test can drive it from the
  /// binding's fake clock; pointer events carry no usable time of their own
  /// under test.
  final int Function() nowMs;

  @override
  State<EntryTriggerLayer> createState() => _EntryTriggerLayerState();
}

class _EntryTriggerLayerState extends State<EntryTriggerLayer>
    with WidgetsBindingObserver {
  final Map<int, _Pointer> _live = {};
  final List<TouchEvent> _buffer = [];
  Timer? _holdTimer;
  int? _holdPointer;
  Timer? _backupTimer;

  /// The safe box (dp) positions are measured in, and where it sits inside
  /// this widget.
  Rect _safe = Rect.zero;
  Rect _counted = Rect.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _holdTimer?.cancel();
    _backupTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A half-made move never survives a background, a shade pull or a system
    // dialog — the same rule the News cover applied to its own counters.
    if (state != AppLifecycleState.resumed) _reset();
  }

  void _reset() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdPointer = null;
    _backupTimer?.cancel();
    _backupTimer = null;
    _live.clear();
    _buffer.clear();
  }

  CoverEntryController get _c => widget.controller;

  bool get _matching => _c.mode == EntryLayerMode.watch;

  TouchTrigger? get _touchTrigger {
    final t = _c.trigger;
    if (t is! TouchTrigger || !_matching) return null;
    return t.boxMatches(_safe.size) ? t : null;
  }

  Offset _units(Offset p) => toShortSide(p - _safe.topLeft, _safe.size);

  void _fire(EntrySource source) {
    // The cover's own recognisers are still waiting for these pointers to
    // come up, and a tap on release would fire the control under the finger
    // — the Notes editor over the PIN pad, a microphone under it. A cancel
    // instead of an up means nothing underneath acts.
    for (final id in _live.keys) {
      GestureBinding.instance.cancelPointer(id);
    }
    _reset();
    _c.onOpen(source);
  }

  void _onDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    if (!_counted.contains(e.localPosition)) return;
    final now = widget.nowMs();
    final p = _Pointer(down: e.localPosition, downMs: now);
    _live[e.pointer] = p;
    if (_live.length >= 2) {
      // A second finger ends any single-finger move in progress, and a third
      // ends the backup hold. Exactly two still fingers is the only thing
      // that counts from here.
      for (final other in _live.values) {
        other.multi = true;
      }
      _buffer.clear();
      _holdTimer?.cancel();
      _holdTimer = null;
      _holdPointer = null;
      _backupTimer?.cancel();
      _backupTimer = null;
      if (_live.length == 2 && _c.mode == EntryLayerMode.watch) {
        _backupTimer = Timer(kCoverRecoveryHold, () {
          _backupTimer = null;
          _fire(EntrySource.backup);
        });
      }
      return;
    }
    final t = _touchTrigger;
    if (t == null) return;
    if (_buffer.isNotEmpty && now - _buffer.last.upMs > t.gapMs) {
      _buffer.clear();
    }
    final u = _units(e.localPosition);
    final wait = t.armedHoldMs(_buffer, x: u.dx, y: u.dy, downMs: now);
    if (wait == null) return;
    _holdPointer = e.pointer;
    _holdTimer = Timer(Duration(milliseconds: wait), () {
      _holdTimer = null;
      _holdPointer = null;
      _fire(EntrySource.custom);
    });
  }

  void _onMove(PointerMoveEvent e) {
    final p = _live[e.pointer];
    if (p == null) return;
    p.maxDist = math.max(p.maxDist, (e.localPosition - p.down).distance);
    if (_holdPointer == e.pointer && p.maxDist > kEntrySlop) {
      _holdTimer?.cancel();
      _holdTimer = null;
      _holdPointer = null;
    }
    if (_backupTimer != null && p.maxDist > kBackupSlop) {
      _backupTimer?.cancel();
      _backupTimer = null;
    }
  }

  void _onUp(PointerUpEvent e) {
    final p = _live.remove(e.pointer);
    if (p == null) return;
    if (_holdPointer == e.pointer) {
      _holdTimer?.cancel();
      _holdTimer = null;
      _holdPointer = null;
    }
    if (_backupTimer != null) {
      _backupTimer?.cancel();
      _backupTimer = null;
    }
    if (p.multi) return;
    if (p.maxDist > kEntrySlop) {
      // A scroll in the middle of a sequence resets it: a stranger scrolling
      // a list must not be accumulating steps.
      _buffer.clear();
      return;
    }
    final now = widget.nowMs();
    final u = _units(p.down);
    final event = TouchEvent(
      x: u.dx,
      y: u.dy,
      durMs: now - p.downMs,
      downMs: p.downMs,
      upMs: now,
    );
    if (_c.mode == EntryLayerMode.record) {
      _c.onRecordedTouch?.call(event);
      return;
    }
    final t = _touchTrigger;
    if (t == null) return;
    _buffer.add(event);
    while (_buffer.length > t.steps.length) {
      _buffer.removeAt(0);
    }
    if (!t.matchesTail(_buffer)) return;
    // This up is still on its way to the cover's recognisers (the binding
    // routes it after the widgets), and a tap on release would fire the
    // control under the last finger — an article, the Notes +. A cancel
    // routed ahead of it makes every recogniser tracking this pointer drop
    // it, so the real up arrives to nobody.
    GestureBinding.instance.pointerRouter.route(
      PointerCancelEvent(
        pointer: e.pointer,
        kind: e.kind,
        position: e.position,
        timeStamp: e.timeStamp,
      ),
    );
    _fire(EntrySource.custom);
  }

  void _onCancel(PointerCancelEvent e) {
    if (_live.remove(e.pointer) == null) return;
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final pad = media.padding;
        _safe = Rect.fromLTRB(
          pad.left,
          pad.top,
          size.width - pad.right,
          size.height - pad.bottom,
        );
        final gesture = media.systemGestureInsets;
        _counted = Rect.fromLTRB(
          _safe.left + math.max(kEdgeBand, gesture.left),
          _safe.top + math.max(kEdgeBand, gesture.top),
          _safe.right - math.max(kEdgeBand, gesture.right),
          _safe.bottom - math.max(kEdgeBand, gesture.bottom),
        );
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerCancel: _onCancel,
          child: widget.child,
        );
      },
    );
  }
}
