import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/features/chat/chat_reactions.dart';

/// One item of the bar, and the side of the pill's padding.
const double _itemSize = 40;
const double _barPad = 6;
const double _itemGap = 2;

/// The pill's hairline, as one value both the paint and the measurement read.
///
/// A border draws INSIDE the box, so leaving its width out of [reactionBarSize]
/// makes the row two pixels wider than the space it is given — an overflow
/// stripe across the whole bar. Written once here rather than as a constant
/// beside a literal, because those are what drift.
const BorderSide _barEdge = BorderSide(color: MilesColors.hairline);

/// How far the bar floats off the message it belongs to.
const double _anchorGap = 8;

/// The smallest margin the bar may leave against any screen edge.
const double _edgeMargin = 8;

/// Returned instead of an emoji when the user asks for the full set.
///
/// A sentinel rather than a nullable second return value: the caller has to
/// handle "dismissed" anyway, and a third state that reads as an emoji string
/// would be indistinguishable from one at every call site.
///
/// Spelled out in ASCII on purpose. This was briefly a string beginning
/// with a literal NUL - which worked, and which quietly made this whole
/// file BINARY to git: it would have committed with no diff and could not
/// have been reviewed. A sentinel only has to be something no emoji can
/// equal, and being readable costs nothing.
const String kReactionMore = '__reaction_more__';

/// The size the bar will take. Pure, so the geometry below can be checked
/// without laying anything out.
Size reactionBarSize({int quickCount = 6}) {
  final n = quickCount + 1; // the quick set, plus the "more" button
  final chrome = (_barPad + _barEdge.width) * 2;
  return Size(
    chrome + n * _itemSize + (n - 1) * _itemGap,
    chrome + _itemSize,
  );
}

/// Where the bar sits for a message whose row occupies [anchor].
///
/// Above the message by default, because that is where a thumb is not. Below it
/// when there is no room above — which is the FIRST message of a conversation,
/// the one case that would otherwise open a bar clipped off the top of the
/// screen. Then clamped into the safe area on both axes, so the last message
/// cannot push it under the input bar either.
///
/// Horizontally it hugs the side the message is on, then clamps: a bar centred
/// on a narrow bubble at the screen edge is the other way this gets clipped.
@visibleForTesting
Offset reactionBarOffset({
  required Rect anchor,
  required Size screen,
  required EdgeInsets insets,
  required Size bar,
  required bool mine,
}) {
  const minX = _edgeMargin;
  final maxX = math.max(minX, screen.width - bar.width - _edgeMargin);
  final x = (mine ? anchor.right - bar.width : anchor.left).clamp(minX, maxX);

  final minY = insets.top + _edgeMargin;
  final maxY =
      math.max(minY, screen.height - insets.bottom - bar.height - _edgeMargin);
  var y = anchor.top - bar.height - _anchorGap;
  if (y < minY) y = anchor.bottom + _anchorGap;
  return Offset(x, y.clamp(minY, maxY));
}

/// The emoji bar a long press opens over a message.
///
/// A route rather than an [OverlayEntry]: back and a tap outside then both
/// close it for free, with no second dismissal path to keep in step with the
/// first. The barrier is transparent and nothing under it moves, so opening the
/// bar cannot shift the conversation by a pixel.
class ReactionBar {
  ReactionBar._();

  /// Opens over [anchor] and answers the chosen emoji, [kReactionMore], or null
  /// if the user dismissed it.
  static Future<String?> show(
    BuildContext context, {
    required Rect anchor,
    required bool mine,
    String? current,
  }) {
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context);
    // The keyboard is part of the bottom edge, and since the bar stopped
    // taking focus it STAYS UP while the bar is open — which is the whole
    // point of that fix and also what exposed this: padding.bottom is 0 with
    // an IME showing, so a bar placed below a tall message near the top of the
    // viewport landed behind the keyboard, invisible and untappable.
    final insets = EdgeInsets.only(
      top: padding.top,
      bottom: math.max(padding.bottom, keyboard.bottom),
    );
    final bar = reactionBarSize();
    final at = reactionBarOffset(
      anchor: anchor,
      screen: screen,
      insets: insets,
      bar: bar,
      mine: mine,
    );
    // Grows from the corner nearest the message, so it reads as coming out of
    // the bubble rather than arriving from the middle of the screen.
    final origin = Alignment(mine ? 1 : -1, at.dy > anchor.top ? -1 : 1);
    // One per open, not one per frame: transitionBuilder runs on every frame
    // of the 170ms, and a CurvedAnimation registers a status listener on the
    // route's animation that nothing here removes (route_motion.dart has the
    // count). Not a CurveTween, because the close has its own curve and a
    // tween has no way to carry one. It dies with the route.
    CurvedAnimation? curve;

    return showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close reactions',
      barrierColor: Colors.transparent,
      // The bar takes no focus. With the default, pushing this route moves
      // first focus to the modal scope, which unfocuses the composer and closes
      // the keyboard — and the Scaffold then grows ~300dp at the bottom, so the
      // whole conversation slides down out from under a bar that was pinned to
      // where the message USED to be. Nothing here needs focus; every item is a
      // GestureDetector.
      requestFocus: false,
      transitionDuration: const Duration(milliseconds: 170),
      pageBuilder: (_, __, ___) => Stack(
        children: [
          Positioned(
            left: at.dx,
            top: at.dy,
            width: bar.width,
            height: bar.height,
            child: _Bar(current: current),
          ),
        ],
      ),
      transitionBuilder: (_, animation, __, child) {
        final scale = curve ??= CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
          reverseCurve: Curves.easeIn,
        );
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: scale, alignment: origin, child: child),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({this.current});

  /// The emoji this user has already left here, drawn held down.
  final String? current;

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: Container(
          padding: const EdgeInsets.all(_barPad),
          decoration: BoxDecoration(
            color: MilesColors.surface2,
            borderRadius: BorderRadius.circular(_itemSize),
            border: const Border.fromBorderSide(_barEdge),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final emoji in ChatReactionRepository.quick) ...[
                _Item(
                  selected: emoji == current,
                  onTap: () => Navigator.pop(context, emoji),
                  child: Text(emoji, style: const TextStyle(fontSize: 24)),
                ),
                const SizedBox(width: _itemGap),
              ],
              _Item(
                selected: false,
                onTap: () => Navigator.pop(context, kReactionMore),
                child: const Icon(Icons.add, size: 22, color: MilesColors.taupe),
              ),
            ],
          ),
        ),
      );
}

class _Item extends StatelessWidget {
  const _Item({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: _itemSize,
          height: _itemSize,
          alignment: Alignment.center,
          decoration: selected
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  color: MilesColors.tint(MilesColors.ember, 0.26,
                      over: MilesColors.surface2,),
                )
              : null,
          child: child,
        ),
      );
}

/// Everything else, when the six on the bar are not the one.
///
/// A grid of this app's own rather than a picker dependency: a keyboard-style
/// picker drags in a package and a platform surface for what is a fixed list of
/// glyphs, and every one of these had to be read anyway — the app authors no
/// suggestive copy, and an emoji the app offers is copy it authored.
Future<String?> showReactionPicker(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: MilesColors.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => const _ReactionPickerSheet(),
    );

/// Seventy-two emoji is past the point where scanning beats typing, so the
/// sheet searches. Recovered from build 52 — see docs/archive/BUILD-52-AUDIT.md.
class _ReactionPickerSheet extends StatefulWidget {
  const _ReactionPickerSheet();

  @override
  State<_ReactionPickerSheet> createState() => _ReactionPickerSheetState();
}

class _ReactionPickerSheetState extends State<_ReactionPickerSheet> {
  String _query = '';

  List<String> get _matches {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return kReactionPalette;
    return [
      for (final e in kReactionPalette)
        if ((kReactionKeywords[e] ?? '').contains(q)) e,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return SafeArea(
      child: Padding(
        // The keyboard's own inset, so the grid is not hidden under it.
        padding: EdgeInsets.fromLTRB(
          12,
          14,
          12,
          12 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 8, bottom: 8),
              child: Text(
                'Pick a reaction',
                style: TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextField(
              style: const TextStyle(color: MilesColors.cream50),
              decoration: const InputDecoration(
                hintText: 'Search emoji',
                prefixIcon: Icon(Icons.search, color: MilesColors.taupe),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 10),
            if (matches.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text('No emoji for that',
                      style: TextStyle(color: MilesColors.taupe),),
                ),
              )
            else
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 52,
                  ),
                  itemCount: matches.length,
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.pop(context, matches[i]);
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: Text(matches[i],
                          style: const TextStyle(fontSize: 26),),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The full set the "+" opens.
///
/// Warm, plain and deliberately unsuggestive — the app supplies private space,
/// never the content. Whatever two people mean by any of these is theirs.
const List<String> kReactionPalette = <String>[
  '❤️', '🧡', '💛', '💚', '💙', '💜', '🤍', '💖',
  '😂', '🤣', '😊', '😍', '🥰', '😘', '🤗', '😌',
  '😮', '😲', '🤯', '🥺', '😢', '😭', '😔', '😞',
  '🙏', '👍', '👎', '👏', '🙌', '🤝', '✌️', '🫶',
  '🔥', '✨', '🌟', '💫', '🎉', '🥳', '🎈', '🎁',
  '☀️', '🌙', '⭐', '🌈', '🌸', '🌹', '🌻', '🍀',
  '☕', '🍰', '🍕', '🍫', '🍦', '🥂', '🍓', '🍉',
  '🎵', '🎧', '📷', '✈️', '🏡', '🚗', '⏰', '💤',
  '🤔', '🙃', '😴', '🤒', '😅', '😉', '🫂', '💌',
];

/// Search terms per emoji.
///
/// Written out rather than derived: Flutter has no Unicode name table at
/// runtime, and the words people actually type ("heart", "laugh", "sorry") are
/// not the official names anyway. Lower-case, and matched as a substring so
/// "lau" finds laughing.
const Map<String, String> kReactionKeywords = <String, String>{
  '❤️': 'heart red love',
  '🧡': 'heart orange love',
  '💛': 'heart yellow love',
  '💚': 'heart green love',
  '💙': 'heart blue love',
  '💜': 'heart purple love',
  '🤍': 'heart white love',
  '💖': 'heart sparkle love shine',
  '😂': 'laugh cry funny joy',
  '🤣': 'laugh rolling funny',
  '😊': 'smile happy blush',
  '😍': 'love eyes adore',
  '🥰': 'love hearts adore smile',
  '😘': 'kiss blow love',
  '🤗': 'hug arms',
  '😌': 'relieved calm content',
  '😮': 'surprise open mouth wow',
  '😲': 'astonished shock wow',
  '🤯': 'mind blown shock',
  '🥺': 'pleading please puppy eyes',
  '😢': 'sad cry tear',
  '😭': 'sob cry sad',
  '😔': 'sad down pensive',
  '😞': 'disappointed sad',
  '🙏': 'pray thanks please sorry',
  '👍': 'thumbs up yes good ok',
  '👎': 'thumbs down no bad',
  '👏': 'clap applause well done',
  '🙌': 'raise hands celebrate praise',
  '🤝': 'handshake deal agree',
  '✌️': 'peace victory',
  '🫶': 'heart hands love',
  '🔥': 'fire hot lit',
  '✨': 'sparkles shine magic',
  '🌟': 'star glow shine',
  '💫': 'dizzy star swirl',
  '🎉': 'party celebrate congrats',
  '🥳': 'party face celebrate',
  '🎈': 'balloon party',
  '🎁': 'gift present',
  '☀️': 'sun sunny day',
  '🌙': 'moon night',
  '⭐': 'star',
  '🌈': 'rainbow',
  '🌸': 'blossom flower pink spring',
  '🌹': 'rose flower red',
  '🌻': 'sunflower flower yellow',
  '🍀': 'clover luck lucky',
  '☕': 'coffee tea cup',
  '🍰': 'cake slice dessert',
  '🍕': 'pizza food',
  '🍫': 'chocolate sweet',
  '🍦': 'ice cream dessert',
  '🥂': 'cheers toast drinks',
  '🍓': 'strawberry fruit',
  '🍉': 'watermelon fruit',
  '🎵': 'music note song',
  '🎧': 'headphones music listen',
  '📷': 'camera photo picture',
  '✈️': 'plane flight travel',
  '🏡': 'home house',
  '🚗': 'car drive',
  '⏰': 'clock alarm time',
  '💤': 'sleep zzz tired',
  '🤔': 'think hmm wonder',
  '🙃': 'upside down silly',
  '😴': 'sleep sleeping tired',
  '🤒': 'sick ill unwell',
  '😅': 'sweat smile nervous phew',
  '😉': 'wink',
  '🫂': 'hug hugging comfort',
  '💌': 'love letter note',
};
