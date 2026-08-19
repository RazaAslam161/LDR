import 'package:flutter/material.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_reactions.dart';

/// One emoji as it is drawn under a bubble: the glyph, how many people chose
/// it, and whether this user is one of them.
@immutable
class ReactionTally {
  const ReactionTally({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.at,
  });

  final String emoji;
  final int count;
  final bool mine;

  /// The newest write among the people merged into this chip.
  ///
  /// What decides whether the chip is ARRIVING or merely being re-drawn. A
  /// reversed ListView.builder garbage-collects rows 250px outside the viewport
  /// and re-inflates them on the way back, which remounts the chip and would
  /// otherwise replay its entrance every time the user scrolls past a message
  /// they reacted to a week ago.
  final DateTime at;
}

/// Collapses one message's reactions into what the chips draw.
///
/// Two people can land on the same emoji, and drawing that as two identical
/// chips reads as a rendering bug — so identical glyphs merge and carry a
/// count. Ordered by who reacted first, so a chip never jumps sideways when the
/// second person joins it.
List<ReactionTally> tallyReactions(
  Map<String, ChatReaction> byUser,
  String? myUid,
) {
  final entries = byUser.entries.toList()
    ..sort((a, b) => a.value.at.compareTo(b.value.at));
  final order = <String>[];
  final counts = <String, int>{};
  final newest = <String, DateTime>{};
  final mine = <String>{};
  for (final e in entries) {
    final emoji = e.value.emoji;
    if (!counts.containsKey(emoji)) order.add(emoji);
    counts[emoji] = (counts[emoji] ?? 0) + 1;
    // `entries` is sorted ascending, so the last one wins.
    newest[emoji] = e.value.at;
    if (e.key == myUid) mine.add(emoji);
  }
  return [
    for (final emoji in order)
      ReactionTally(
        emoji: emoji,
        count: counts[emoji]!,
        mine: mine.contains(emoji),
        at: newest[emoji]!,
      ),
  ];
}

/// The row of reaction chips under one message.
///
/// Wrapped in an [AnimatedSize] because this is the one place a reaction can
/// move the conversation: the first chip on a message makes that bubble ~22dp
/// taller, and in a reversed list every older message above it steps up by
/// that much. Growing over 160ms turns a jump into a nudge, and it is the same
/// motion whether the reaction is this user's own (already painted before the
/// network was touched) or the partner's arriving over the wire.
class ReactionChips extends StatelessWidget {
  const ReactionChips({
    required this.byUser,
    required this.myUid,
    required this.mine,
    required this.onTap,
    super.key,
  });

  final Map<String, ChatReaction> byUser;
  final String? myUid;

  /// Whether the message is this user's, which is the side the chips sit on.
  final bool mine;

  /// Toggling: tapping the emoji you already left takes it back.
  final void Function(String emoji) onTap;

  @override
  Widget build(BuildContext context) {
    final tallies = tallyReactions(byUser, myUid);
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: tallies.isEmpty
          ? const SizedBox(width: double.infinity, height: 0)
          : Padding(
              padding: EdgeInsets.only(
                left: mine ? 0 : 6,
                right: mine ? 6 : 0,
                top: 2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment:
                    mine ? MainAxisAlignment.end : MainAxisAlignment.start,
                children: [
                  for (final t in tallies)
                    // The key belongs on the Row's DIRECT child. One level
                    // down, reconciliation matches unkeyed Paddings slot for
                    // slot first and only then compares keys — so removing the
                    // first of two chips handed the survivor the first slot's
                    // element, saw the keys differ, and remounted it: the chip
                    // that did not change popped, every time the other one
                    // went away.
                    Padding(
                      key: ValueKey(t.emoji),
                      padding: const EdgeInsets.only(right: 4),
                      child: _Chip(
                        tally: t,
                        onTap: () => onTap(t.emoji),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.tally, required this.onTap});

  /// How recent a reaction has to be for the chip to play its entrance.
  ///
  /// Mounting is not the same event as arriving: a scrolled-away row is
  /// re-inflated from scratch when it comes back, and an old reaction popping
  /// in every time the user passes it is the jump this feature is not allowed
  /// to have. Comfortably longer than the wire takes and far shorter than a
  /// scroll back.
  static const _entrance = Duration(seconds: 3);

  final ReactionTally tally;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The lower bound is not decoration. `tally.at` is the OTHER device's
    // clock, so a partner whose handset runs ten minutes fast stamps every
    // reaction ten minutes in the future — and a bare `< _entrance` is
    // satisfied by any negative difference, which would replay the entrance on
    // every remount for the whole length of the skew. That is exactly the
    // scroll-past pop this gate exists to stop, so a future-dated reaction is
    // treated as not arriving.
    final age = DateTime.now().difference(tally.at);
    final arriving = !age.isNegative && age < _entrance;
    return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: TweenAnimationBuilder<double>(
          // Always present, so the tree shape never changes under an element
          // that is being reused. Equal ends make it inert: TweenAnimationBuilder
          // only drives the controller when begin differs from end.
          tween: Tween(begin: arriving ? 0.6 : 1, end: 1),
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutBack,
          builder: (_, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: tally.mine
                  ? MilesColors.tint(MilesColors.ember, 0.22)
                  : MilesColors.surface2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: tally.mine
                    ? MilesColors.ember.withValues(alpha: 0.55)
                    : MilesColors.hairline,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tally.emoji, style: const TextStyle(fontSize: 13)),
                if (tally.count > 1) ...[
                  const SizedBox(width: 3),
                  Text(
                    '${tally.count}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: MilesColors.cream100,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
  }
}
