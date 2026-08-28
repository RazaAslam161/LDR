import 'package:flutter/material.dart';

/// The faces during a screen share, in one horizontal strip.
///
/// While a share holds the big view, nobody should have to give up seeing
/// anybody: every camera lives here as a mini tile — centred while they fit,
/// and smoothly scrollable with a bounce the moment they don't, so the layout
/// never has to change shape for a third tile. (Patterns proven in the chat
/// viewer's `_Filmstrip` and the rapid camera's filter strip.)
///
/// Takes plain widgets rather than renderers so widget tests can pump it with
/// ordinary boxes — RTCVideoView needs the platform channel.
class FaceStrip extends StatelessWidget {
  const FaceStrip({required this.tiles, super.key});

  final List<Widget> tiles;

  static const double height = 150;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Center(
          // shrinkWrap keeps the list content-width so Center can centre it;
          // past the viewport it scrolls like any list.
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            shrinkWrap: true,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: tiles.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => tiles[i],
          ),
        ),
      );
}
