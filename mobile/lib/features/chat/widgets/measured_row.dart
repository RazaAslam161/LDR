import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Reports how tall its child actually laid out.
///
/// The chat needs this because a `ListView.builder` will not say where a row
/// is, and a jump to a message eighty rows back has to know. Heights are read
/// from layout rather than guessed from content: a bubble is one line or ten,
/// a photo grid or a voice note, and every guess is wrong for some of them.
///
/// The callback fires during layout and must therefore only record — never
/// setState, never mark anything dirty. Its one consumer writes to a map.
class MeasuredRow extends SingleChildRenderObjectWidget {
  const MeasuredRow({
    required this.onHeight,
    required Widget super.child,
    super.key,
  });

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredRow(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasuredRow renderObject,
  ) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderMeasuredRow extends RenderProxyBox {
  _RenderMeasuredRow(this.onHeight);

  ValueChanged<double> onHeight;

  /// Only report a change. A sliver re-lays-out its children freely, and a
  /// callback on every pass would be thousands of map writes a second while
  /// scrolling to say the same number.
  double _lastReported = -1;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height != _lastReported) {
      _lastReported = height;
      onHeight(height);
    }
  }
}
