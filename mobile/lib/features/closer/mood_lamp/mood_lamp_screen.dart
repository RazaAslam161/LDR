import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';

/// Mood Lamp — pick a color; it glows on your partner's screen in real time.
/// Pure broadcast, no persistence. Soft, ambient, no words.
class MoodLampScreen extends ConsumerStatefulWidget {
  const MoodLampScreen({super.key});

  @override
  ConsumerState<MoodLampScreen> createState() => _MoodLampScreenState();
}

class _MoodLampScreenState extends ConsumerState<MoodLampScreen> {
  ManagedSubscription? _channel;
  Color _myColor = const Color(0xFFEF6F58);
  Color _partnerColor = const Color(0xFF1F2937); // dark = "no mood set"
  Timer? _autoFadeTimer;

  // A curated warm palette — not a full color wheel, because mood ≠ pixel-picking.
  static const _palette = <Color>[
    Color(0xFFEF6F58), // coral — "warm, want you"
    Color(0xFFF4937E), // peach — "soft, missing you"
    Color(0xFFFBBF24), // amber — "happy, glowing"
    Color(0xFF34D399), // emerald — "calm, present"
    Color(0xFFA78BFA), // violet — "dreamy"
    Color(0xFF60A5FA), // blue — "tender, pensive"
    Color(0xFFF472B6), // pink — "playful"
    Color(0xFF0B0F16), // off — clear my lamp
  ];

  @override
  void initState() {
    super.initState();
    final couple = ref.read(sessionProvider).couple;
    final coupleId = couple?.id ?? 'none';

    _channel = ManagedSubscription.start(
      () => SupabaseService.client.channel('mood_lamp:$coupleId').onBroadcast(
        event: 'mood',
        callback: (payload) {
          final from = payload['from'] as String?;
          if (from == ref.read(sessionProvider).profile?.id) return;
          final rgb = (payload['rgb'] as num).toInt();
          setState(() => _partnerColor = Color(rgb | 0xFF000000));
        },
      ).subscribe(),
    );
  }

  @override
  void dispose() {
    _autoFadeTimer?.cancel();
    _channel?.dispose();
    super.dispose();
  }

  void _pickColor(Color c) {
    setState(() => _myColor = c);
    final rgb = (c.red << 16) | (c.green << 8) | c.blue;

    final me = ref.read(sessionProvider).profile;
    _channel?.channel?.sendBroadcastMessage(
      event: 'mood',
      payload: {'from': me?.id, 'rgb': rgb},
    );

    // Auto-fade after 4 hours — but also reset to "off" if user picks the
    // dark swatch.
    _autoFadeTimer?.cancel();
    if (c != _palette.last) {
      _autoFadeTimer = Timer(const Duration(hours: 4), () {
        _pickColor(_palette.last);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F16),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back,
                        color: Color(0x80F5EFE6),),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mood Lamp',
                          style: TextStyle(
                            color: Color(0xFFFBF8F4),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'A color, no words',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0x66F5EFE6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Lamp visuals — two glowing orbs
            Expanded(
              child: _LampView(myColor: _myColor, partnerColor: _partnerColor),
            ),

            // Palette
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Column(
                children: [
                  const Text(
                    'PICK A MOOD',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 3,
                      color: Color(0x66F5EFE6),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final c in _palette)
                        GestureDetector(
                          onTap: () => _pickColor(c),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: _myColor == c
                                  ? Border.all(
                                      color: const Color(0xFFFBF8F4),
                                      width: 2,
                                    )
                                  : Border.all(
                                      color: const Color(0x33F5EFE6),
                                    ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Two softly-glowing orbs side by side: yours, theirs.
class _LampView extends StatelessWidget {
  const _LampView({required this.myColor, required this.partnerColor});
  final Color myColor;
  final Color partnerColor;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _Orb(color: myColor, label: 'You'),
          // Connector — a thin warm line between the two lamps
          Container(
            width: 40,
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  myColor.withValues(alpha: 0.5),
                  partnerColor.withValues(alpha: 0.5),
                ],
              ),
            ),
          ),
          _Orb(color: partnerColor, label: 'Them'),
        ],
      ),
    );
  }
}

class _Orb extends StatelessWidget {
  const _Orb({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final isOff = color == const Color(0xFF0B0F16) ||
        color == const Color(0xFF1F2937);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 140,
          height: 140,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isOff ? const Color(0xFF141B26) : color.withValues(alpha: 0.2),
            boxShadow: isOff
                ? null
                : [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5),
                      blurRadius: 60,
                      spreadRadius: 12,
                    ),
                  ],
            border: Border.all(
              color: isOff
                  ? const Color(0x1aF5EFE6)
                  : color.withValues(alpha: 0.6),
              width: 1.5,
            ),
          ),
          child: Center(
            child: isOff
                ? const Text(
                    '—',
                    style: TextStyle(color: Color(0x66F5EFE6), fontSize: 32),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0x80F5EFE6)),
        ),
      ],
    );
  }
}
