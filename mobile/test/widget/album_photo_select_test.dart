import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miles/core/widgets/drag_select.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/media_album.dart';
import 'package:miles/features/chat/widgets/album_bubble.dart';

/// Picking ONE photograph out of a send.
///
/// An album is one row of the conversation, so for as long as the drag index
/// space was rows a finger could only ever resolve to the whole send. These
/// pin the two halves of the fix: a tile carries a conversation-wide index of
/// its own, and while a selection is open its tap goes to the selection rather
/// than to the viewer.
void main() {
  Message photo(String id) => Message(
        id: id,
        senderId: 'me',
        createdAt: DateTime(2026),
        kind: 'image',
        sendStatus: SendStatus.sent,
      );

  ChatRow rowOf(int n) =>
      ChatRow([for (var i = 0; i < n; i++) photo('m$i')]);

  Widget harness(
    ChatRow row, {
    required bool selecting,
    required List<int> opened,
    required List<int> toggled,
    Set<int> selected = const {},
    int baseIndex = 0,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: AlbumBubble(
                row: row,
                baseIndex: baseIndex,
                selecting: selecting,
                isSelected: selected.contains,
                onOpen: opened.add,
                onToggleOne: toggled.add,
              ),
            ),
          ),
        ),
      );

  testWidgets('outside a selection a tile still opens the viewer',
      (tester) async {
    final opened = <int>[];
    final toggled = <int>[];
    await tester.pumpWidget(harness(rowOf(4),
        selecting: false, opened: opened, toggled: toggled,));

    await tester.tap(find.byType(DragSelectItem).at(1));
    await tester.pump();

    expect(opened, [1], reason: 'the viewer is what a tap means normally');
    expect(toggled, isEmpty);
  });

  testWidgets('inside a selection a tile picks THAT photo, not the send',
      (tester) async {
    final opened = <int>[];
    final toggled = <int>[];
    await tester.pumpWidget(harness(rowOf(4),
        selecting: true, opened: opened, toggled: toggled,));

    await tester.tap(find.byType(DragSelectItem).at(2));
    await tester.pump();

    expect(toggled, [2]);
    expect(opened, isEmpty, reason: 'opening mid-selection loses the batch');
  });

  testWidgets('every tile carries a conversation-wide index, not a row-local one',
      (tester) async {
    // The index a drag resolves a finger to has to be comparable across rows,
    // so a tile in the fourth row cannot be numbered from zero.
    await tester.pumpWidget(harness(rowOf(4),
        selecting: true, opened: [], toggled: [], baseIndex: 17,));

    final tags = tester
        .widgetList<DragSelectItem>(find.byType(DragSelectItem))
        .map((w) => w.index)
        .toList();
    expect(tags, [17, 18, 19, 20]);
  });

  testWidgets('a send of twenty draws four tiles, so four are pickable',
      (tester) async {
    // The fourth stands for the sixteen behind it — the screen handles that by
    // taking the remainder with it; what this pins is that the grid does not
    // silently offer twenty targets it never painted.
    await tester.pumpWidget(harness(rowOf(20),
        selecting: true, opened: [], toggled: [],));

    expect(find.byType(DragSelectItem), findsNWidgets(4));
    expect(find.text('+16'), findsOneWidget);
  });

  testWidgets('a selected tile is marked and an unselected one is not',
      (tester) async {
    await tester.pumpWidget(harness(rowOf(4),
        selecting: true, opened: [], toggled: [], selected: {0, 2},));

    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
  });

  testWidgets('with no selection open no tile wears a checkbox',
      (tester) async {
    await tester.pumpWidget(harness(rowOf(4),
        selecting: false, opened: [], toggled: [],));

    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
  });
}
