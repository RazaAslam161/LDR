import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:miles/features/closer/touch_trace/touch_trace_canvas.dart';

/// Full-screen Touch Trace experience.
/// Both partners open this screen; whatever one draws appears on the other's.
class TouchTraceScreen extends ConsumerStatefulWidget {
  const TouchTraceScreen({super.key});

  @override
  ConsumerState<TouchTraceScreen> createState() => _TouchTraceScreenState();
}

class _TouchTraceScreenState extends ConsumerState<TouchTraceScreen> {
  @override
  void initState() {
    super.initState();
    SecureScreen.acquire(); // intimate — block screenshots / recording
  }

  @override
  void dispose() {
    SecureScreen.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final couple = session.couple;
    final me = session.profile;
    final partner = session.partner;

    // Guard: needs a linked couple with both partners
    if (couple == null || me == null || partner == null) {
      return const Scaffold(
        body: Center(
          child: Text(
            'Link your partner to draw together.',
            style: TextStyle(color: Color(0x99F5EFE6)),
          ),
        ),
      );
    }

    // FLAG_SECURE prevents screenshots / screen recording inside Touch Trace.
    // Available on Android; no-op on iOS (handled separately).
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
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
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Color(0x80F5EFE6),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Touch Trace',
                            style: TextStyle(
                              color: Color(0xFFFBF8F4),
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Draw together, in real time',
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

              // Canvas
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: TouchTraceCanvas(
                      coupleId: couple.id,
                      userId: me.id,
                      partnerId: partner.id,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
