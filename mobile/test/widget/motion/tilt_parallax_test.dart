import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/tilt_parallax.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// A parallax that leaks its sensor subscription is a battery cost the user
/// cannot see and a disguise cost they cannot afford, so the lifecycle is
/// pinned as hard as the pixels: the stream is only listened to while the
/// widget should move, and it is always released.
void main() {
  AccelerometerEvent tilt(double x, double y) =>
      AccelerometerEvent(x, y, 0, DateTime.now());

  // The default test surface is 800x600 — LANDSCAPE — and this widget maps
  // device axes to screen axes by orientation (Android's sensor frame is
  // fixed to the handset's natural orientation and never rotates with the
  // display). A phone-shaped surface is what these cases are about.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher
        .implicitView!;
    view.physicalSize = const Size(1080, 2280);
    view.devicePixelRatio = 3;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher
        .implicitView!;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  ({Widget widget, StreamController<AccelerometerEvent> source, List<String> log})
      rig({double depth = 4, bool animationsOff = false}) {
    final log = <String>[];
    final source = StreamController<AccelerometerEvent>.broadcast(
      onListen: () => log.add('listen'),
      onCancel: () => log.add('cancel'),
    );
    final widget = MaterialApp(
      home: Scaffold(
        body: Center(
          child: TiltParallax(
            depth: depth,
            debugSource: source.stream,
            child: const SizedBox(width: 100, height: 100, child: Text('hero')),
          ),
        ),
      ),
      builder: !animationsOff
          ? null
          : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: child!,
              ),
    );
    return (widget: widget, source: source, log: log);
  }

  double dx(WidgetTester tester) => tester
      .widgetList<Transform>(find.ancestor(
        of: find.text('hero'),
        matching: find.byType(Transform),
      ))
      .map((t) => t.transform.getTranslation().x)
      .fold(0, (a, b) => a.abs() > b.abs() ? a : b);

  /// Settle at an upright portrait rest, then hold [x],[y] — the shape every
  /// case needs now that "level" is learned rather than assumed.
  Future<void> restThenHold(
    WidgetTester tester,
    StreamController<AccelerometerEvent> source, {
    required double x,
    required double y,
  }) async {
    for (var i = 0; i < 30; i++) {
      source.add(tilt(0, 9.8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 30; i++) {
      source.add(tilt(x, y));
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('a hard tilt never moves the hero further than depth',
      (tester) async {
    final r = rig(depth: 4);
    await tester.pumpWidget(r.widget);
    // Far past gravity — the clamp is the whole point.
    await restThenHold(tester, r.source, x: 40, y: -40);
    expect(dx(tester).abs(), lessThanOrEqualTo(4.001),
        reason: 'the lean is clamped to depth, whatever the sensor says');
    expect(dx(tester).abs(), greaterThan(0.5),
        reason: 'and it does actually move — a clamp is not a mute');
    await r.source.close();
  });

  testWidgets('depth above the ceiling is clamped to it', (tester) async {
    final r = rig(depth: 99);
    await tester.pumpWidget(r.widget);
    await restThenHold(tester, r.source, x: 40, y: 9.8);
    expect(dx(tester).abs(), lessThanOrEqualTo(6.001),
        reason: 'past ~6px a card reads as loose, so the widget refuses');
    await r.source.close();
  });

  testWidgets('a phone lying flat on a table rests at zero', (tester) async {
    // The posture that broke the first version: gravity on z, nothing on y,
    // which measured as a permanent -99% lean because "level" was hardcoded
    // as a bolt-upright portrait hold. Rest is learned now, so any steady
    // posture IS rest.
    final r = rig();
    await tester.pumpWidget(r.widget);
    for (var i = 0; i < 60; i++) {
      r.source.add(AccelerometerEvent(0, 0, 9.8, DateTime.now()));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(dx(tester).abs(), lessThan(0.5),
        reason: 'a still phone must not sit railed at its clamp');
    await r.source.close();
  });

  testWidgets('a steady 45-degree hold also rests at zero', (tester) async {
    final r = rig();
    await tester.pumpWidget(r.widget);
    for (var i = 0; i < 60; i++) {
      r.source.add(AccelerometerEvent(0, 6.9, 6.9, DateTime.now()));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(dx(tester).abs(), lessThan(0.5),
        reason: 'the neutral is the posture, not one specific angle');
    await r.source.close();
  });

  testWidgets('a real lean off a learned rest still moves the card',
      (tester) async {
    // The other half of the contract: re-centring must not mute the effect.
    final r = rig();
    await tester.pumpWidget(r.widget);
    for (var i = 0; i < 30; i++) {
      r.source.add(AccelerometerEvent(0, 0, 9.8, DateTime.now())); // flat
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 20; i++) {
      r.source.add(AccelerometerEvent(-4, 0, 9, DateTime.now())); // leaned
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(dx(tester).abs(), greaterThan(0.5),
        reason: 'learning rest must not flatten a genuine tilt');
    await r.source.close();
  });

  testWidgets('animations off = no subscription and a plain child',
      (tester) async {
    final r = rig(animationsOff: true);
    await tester.pumpWidget(r.widget);
    await tester.pump();
    expect(r.log, isEmpty,
        reason: 'off() must not even open the sensor stream');
    r.source.add(tilt(40, -40));
    await tester.pump();
    expect(dx(tester), 0);
    await r.source.close();
  });

  testWidgets('the subscription dies with the widget', (tester) async {
    final r = rig();
    await tester.pumpWidget(r.widget);
    await tester.pump();
    expect(r.log, contains('listen'));
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(r.log, contains('cancel'),
        reason: 'a parallax that keeps sampling after its screen is gone is '
            'a battery cost nobody can see');
    await r.source.close();
  });
}
