import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/lock_screen.dart';

/// The app lock is a security control, and it was throwing every time it
/// raised.
///
/// [LockScreen] returns a `Positioned.fill` of its own. main.dart used to
/// mount it under a `RepaintBoundary`, so the Positioned's nearest ancestor
/// render object was the boundary rather than the Stack — "Incorrect use of
/// ParentDataWidget", which (per the CallPip note in main.dart) greys out
/// the whole app and swallows every touch. No test rendered the locked
/// state, so a green suite said nothing about it.
///
/// This pins the contract from both sides so it cannot come back: the widget
/// is a Positioned, therefore whoever mounts it must mount it DIRECTLY in a
/// Stack.
void main() {
  testWidgets('mounts clean as a direct Stack child', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Stack(children: [LockScreen()]),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a render object between it and the Stack is a defect',
      (tester) async {
    // Documenting the failure mode itself: if this ever stops throwing,
    // LockScreen has stopped being a Positioned and the rule above can be
    // relaxed deliberately rather than by accident.
    await tester.pumpWidget(const MaterialApp(
      home: Stack(children: [
        RepaintBoundary(child: LockScreen()),
      ],),
    ));
    await tester.pump();
    expect(tester.takeException(), isNotNull,
        reason: 'a Positioned must be a direct child of its Stack');
  });
}
