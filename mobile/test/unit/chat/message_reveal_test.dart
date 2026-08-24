import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/chat/message_reveal.dart';

/// Where a row sits in a list that will not say.
///
/// The arithmetic is trivial; what it is worth testing for is the two things
/// that made the FIRST version of this wrong. Heights are keyed by row identity
/// and not by index, because a realtime insert renumbers every older row. And
/// an unmeasured row falls back to the running mean rather than to zero, so the
/// first jump lands close enough for the sequential layout to measure the rest.
void main() {
  List<String> ids(int n) => [for (var i = 0; i < n; i++) 'm$i'];

  test('a fully measured list gives an exact offset', () {
    final o = RowOffsets();
    for (var i = 0; i < 5; i++) {
      o.record('m$i', 100);
    }
    expect(o.offsetOf(ids(5), 0), 0);
    expect(o.offsetOf(ids(5), 3), 300);
    expect(o.isExactFor(ids(5), 3), isTrue);
  });

  test('an unmeasured row is worth the average of the measured ones', () {
    final o = RowOffsets()
      ..record('m0', 100)
      ..record('m1', 300);
    // m2 has never been laid out; the mean of 100 and 300 stands in for it.
    expect(o.offsetOf(ids(4), 3), 100 + 300 + 200);
    expect(o.isExactFor(ids(4), 3), isFalse);
  });

  test('nothing measured at all still produces a usable guess', () {
    final o = RowOffsets();
    expect(o.offsetOf(ids(10), 10), 10 * RowOffsets.coldFallback);
    expect(o.meanHeight, RowOffsets.coldFallback);
  });

  test('heights follow the row, not its position in the list', () {
    // The failure this prevents: a message arrives, every older row's index
    // moves up by one, and an index-keyed map now reports each row's height as
    // its neighbour's.
    final o = RowOffsets()
      ..record('m0', 400)
      ..record('m1', 50);
    final afterInsert = ['new', 'm0', 'm1'];
    // 'new' is unmeasured (mean 225); m0 keeps its own 400.
    expect(o.offsetOf(afterInsert, 2), 225 + 400);
    expect(o.heightOf('m0'), 400);
  });

  test('centring puts the row in the middle of the viewport', () {
    final o = RowOffsets();
    for (var i = 0; i < 20; i++) {
      o.record('m$i', 100);
    }
    // Row 10 starts at 1000; a 600-tall viewport centres a 100-tall row by
    // sitting 250 above it.
    expect(
      o.centredOffsetFor(ids(20), 10, viewport: 600, maxExtent: 5000),
      750,
    );
  });

  test('centring never asks for an offset the list cannot reach', () {
    final o = RowOffsets();
    for (var i = 0; i < 20; i++) {
      o.record('m$i', 100);
    }
    // The newest row: centring it would mean scrolling to a negative offset.
    expect(o.centredOffsetFor(ids(20), 0, viewport: 600, maxExtent: 5000), 0);
    // The oldest, against a short list.
    expect(
      o.centredOffsetFor(ids(20), 19, viewport: 600, maxExtent: 900),
      900,
    );
  });

  test('a deleted row stops taking up space in the map', () {
    final o = RowOffsets()
      ..record('m0', 100)
      ..record('m1', 100)
      ..forgetAllExcept({'m0'});
    expect(o.measuredCount, 1);
    expect(o.heightOf('m1'), isNull);
  });
}
