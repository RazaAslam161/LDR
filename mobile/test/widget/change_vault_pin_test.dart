import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/features/vault/change_pin_screen.dart';

/// The three-step change-PIN machine, on the paths that never reach the server.
///
/// Everything the server does is proved against staging (§315). What cannot be
/// proved there is the client's own sequencing, and the two rules worth pinning
/// are the two that decide whether a user burns a lockout attempt by accident:
/// a mistyped CONFIRMATION must cost nothing, and re-using the current PIN must
/// be refused here rather than sent and reported as a successful change.
void main() {
  Future<void> enter(WidgetTester tester, String pin) async {
    for (final d in pin.split('')) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.pump();
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChangePinScreen()));
    await tester.pump();
  }

  testWidgets('opens asking for the CURRENT pin', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Enter your current PIN'), findsOneWidget);
  });

  testWidgets('the current pin is accepted locally and moves to the new one',
      (tester) async {
    await pumpScreen(tester);
    await enter(tester, '1111');

    expect(find.text('Choose a new PIN'), findsOneWidget);
    // Nothing has been sent: the old PIN is not checked until all three are in
    // hand, so a user who gets this far has spent no lockout attempt.
    expect(find.text('That was not your current PIN.'), findsNothing);
  });

  testWidgets('choosing the SAME pin is refused without asking the server',
      (tester) async {
    await pumpScreen(tester);
    await enter(tester, '1111');
    await enter(tester, '1111');

    expect(find.text('That is already your PIN.'), findsOneWidget);
    expect(find.text('Choose a new PIN'), findsOneWidget,
        reason: 'it stays on the step it rejected, not the confirm step',);
  });

  testWidgets('a mistyped confirmation costs nothing and asks again',
      (tester) async {
    await pumpScreen(tester);
    await enter(tester, '1111'); // current
    await enter(tester, '2222'); // new
    expect(find.text('Confirm your new PIN'), findsOneWidget);

    await enter(tester, '3333'); // does not match

    expect(find.text("Those didn't match — choose a new PIN again."),
        findsOneWidget,);
    // Back to choosing a NEW pin, NOT back to the current one: the current PIN
    // was never in question, and making the user retype it would be the kind
    // of small cruelty that gets a lockout hit on a correct PIN.
    expect(find.text('Choose a new PIN'), findsOneWidget);
  });

  testWidgets('after a mismatch the new pin can be chosen again',
      (tester) async {
    await pumpScreen(tester);
    await enter(tester, '1111');
    await enter(tester, '2222');
    await enter(tester, '3333'); // mismatch, back to choosing

    await enter(tester, '4444');
    expect(find.text('Confirm your new PIN'), findsOneWidget,
        reason: 'the machine is reusable, not wedged after one mistake',);
  });

  testWidgets('closing returns false rather than a bare pop', (tester) async {
    // The vault screen only shows its confirmation when this says true, so a
    // close that returned null-as-success would announce a change that never
    // happened.
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async => result = await ChangePinScreen.open(context),
          child: const Text('go'),
        ),
      ),
    ),);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });
}
