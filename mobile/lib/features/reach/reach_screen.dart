import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vibration/vibration.dart';

/// Reach — feel them through the phone.
///
/// Hold the heart: a heartbeat pattern is sent to your partner's device in
/// real time. They feel the same rhythm as a gentle haptic. No message, no
/// notification, just presence.
class ReachScreen extends ConsumerStatefulWidget {
  const ReachScreen({super.key});

  @override
  ConsumerState<ReachScreen> createState() => _ReachScreenState();
}

class _ReachScreenState extends ConsumerState<ReachScreen> {
  RealtimeChannel? _channel;
  bool _sending = false;
  Timer? _sendTimer;
  Timer? _receivePulseTimer;
  int _pulsesReceived = 0;

  @override
  void dispose() {
    _sendTimer?.cancel();
    _receivePulseTimer?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }

  void _attachChannel(String coupleId) {
    if (_channel != null) return;
    _channel = SupabaseService.client
        .channel('reach:$coupleId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'reach_pulses',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'couple_id',
            value: coupleId,
          ),
          callback: (payload) {
            final fromPartner =
                payload.newRecord['user_id'] != SupabaseService.currentUserId;
            if (fromPartner) _onPulseFromPartner();
          },
        )
        .subscribe();
  }

  /// Approximate a heartbeat — two quick thumps, then a longer rest.
  /// 60 BPM-style: thump (100ms), gap (150ms), thump (100ms), gap (700ms).
  static const _pattern = [0, 100, 150, 100, 700];

  Future<void> _startSending(String coupleId) async {
    setState(() => _sending = true);
    // Immediately pulse once.
    await _broadcastPulse(coupleId);

    _sendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _broadcastPulse(coupleId);
    });
  }

  Future<void> _broadcastPulse(String coupleId) async {
    await SupabaseService.client.from('reach_pulses').insert({
      'couple_id': coupleId,
      'user_id': SupabaseService.currentUserId,
      'sent_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _stopSending() {
    _sendTimer?.cancel();
    setState(() => _sending = false);
  }

  Future<void> _onPulseFromPartner() async {
    setState(() => _pulsesReceived++);
    if (await Vibration.hasVibrator() ?? false) {
      await Vibration.vibrate(pattern: _pattern);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final couple = session.couple;
    if (couple != null) _attachChannel(couple.id);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reach'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                "Hold the heart. They'll feel it — a gentle pulse, "
                'in rhythm with yours.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0x99F5EFE6), fontSize: 14),
              ),
            ),
            const Spacer(),
            GestureDetector(
              onLongPressStart: (_) =>
                  couple != null ? _startSending(couple.id) : null,
              onLongPressEnd: (_) => _stopSending(),
              child: AnimatedScale(
                scale: _sending ? 1.1 : 1,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFFEF6F58).withValues(alpha: 0.6),
                        const Color(0xFFEF6F58).withValues(alpha: 0),
                      ],
                    ),
                  ),
                  child: Icon(
                    _sending ? Icons.favorite : Icons.favorite_outline,
                    color: const Color(0xFFEF6F58),
                    size: 80,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _sending ? 'Sending your pulse…' : 'Hold to reach',
              style: const TextStyle(color: Color(0xFFF4937E), fontSize: 13),
            ),
            const Spacer(),
            if (_pulsesReceived > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: Text(
                  'They reached for you · $_pulsesReceived×',
                  style: const TextStyle(color: Color(0x80F5EFE6)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
