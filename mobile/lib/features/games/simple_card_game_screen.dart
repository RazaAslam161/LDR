import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';

/// A simple, local "tap for the next card" game — used for Would You Rather and
/// Never Have I Ever. Shuffles the deck, shows one prompt at a time. Best played
/// on a call or by passing the phone.
class SimpleCardGameScreen extends StatefulWidget {
  const SimpleCardGameScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.emoji,
    required this.cards,
    this.accent = MilesColors.blush,
  });

  final String title;
  final String subtitle;
  final String emoji;
  final List<String> cards;
  final Color accent;

  @override
  State<SimpleCardGameScreen> createState() => _SimpleCardGameScreenState();
}

class _SimpleCardGameScreenState extends State<SimpleCardGameScreen> {
  late List<int> _order;
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _order = List.generate(widget.cards.length, (i) => i)..shuffle(Random());
  }

  void _next() {
    setState(() {
      _i++;
      if (_i >= _order.length) {
        _order.shuffle(Random());
        _i = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.cards.isEmpty ? '' : widget.cards[_order[_i]];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: EmberBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(widget.subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 13)),
                const SizedBox(height: 20),
                Expanded(
                  child: GestureDetector(
                    onTap: _next,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      child: Container(
                        key: ValueKey(_i),
                        width: double.infinity,
                        padding: const EdgeInsets.all(28),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              widget.accent.withValues(alpha: 0.28),
                              MilesColors.ember.withValues(alpha: 0.16),
                            ],
                          ),
                          border: Border.all(
                              color: widget.accent.withValues(alpha: 0.35)),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(widget.emoji,
                                  style: const TextStyle(fontSize: 44)),
                              const SizedBox(height: 22),
                              Text(card,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: MilesColors.cream50,
                                      fontSize: 21,
                                      height: 1.45,
                                      fontWeight: FontWeight.w500)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('${_i + 1} / ${widget.cards.length}',
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 12)),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: widget.accent,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _next,
                    icon: const Icon(Icons.casino_outlined),
                    label: const Text('Agla card'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
