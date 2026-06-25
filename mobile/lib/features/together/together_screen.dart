import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/screen_presence.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Presence;

class _Action {
  const _Action(this.key, this.emoji, this.label);
  final String key;
  final String emoji;
  final String label;
}

const List<_Action> _actions = [
  _Action('cuddle', '🫂', 'Cuddle'),
  _Action('kiss', '💋', 'Kiss'),
  _Action('hug', '🤗', 'Hug'),
  _Action('hold', '🤝', 'Hold hands'),
  _Action('headpat', '✋', 'Head pat'),
  _Action('boop', '👉', 'Boop'),
];

const List<String> _avatarChoices = [
  '🧑', '👩', '🧔', '👧', '🧑‍🦰', '👩‍🦰', '🧑‍🦱', '👩‍🦱', '😊', '😍', '🥰', '💖',
];

_Action _actionByKey(String? k) =>
    _actions.firstWhere((a) => a.key == k, orElse: () => _actions.first);

class _Moment {
  _Moment(this.id, this.action);
  final int id;
  final _Action action;
}

/// A shared, affectionate avatar space. Each partner picks an avatar; tapping a
/// gesture (cuddle/kiss/hug…) plays it on BOTH screens in real time — the
/// avatars lean together and the gesture animates between them.
class TogetherScreen extends ConsumerStatefulWidget {
  const TogetherScreen({super.key});

  @override
  ConsumerState<TogetherScreen> createState() => _TogetherScreenState();
}

class _TogetherScreenState extends ConsumerState<TogetherScreen> {
  String? _coupleId;
  RealtimeChannel? _channel;
  String _myEmoji = '🧑';
  String _partnerEmoji = '💖';
  final List<_Moment> _moments = [];
  int _nextId = 0;
  bool _close = false; // avatars leaning together

  @override
  void initState() {
    super.initState();
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    _coupleId = couple.id;
    _channel = SupabaseService.client
        .channel('together:${couple.id}')
        .onBroadcast(event: 'moment', callback: _onMoment)
        .subscribe();
    reportScreen(ref, 'Together');
    _load();
  }

  @override
  void dispose() {
    reportActiveTab(ref);
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _load() async {
    final id = _coupleId;
    if (id == null) return;
    final mine = await PresenceService.fetchMine(id);
    final partner = await PresenceService.fetchPartner(id);
    if (mounted) {
      setState(() {
        _myEmoji = mine?.avatarEmoji ?? '🧑';
        _partnerEmoji = partner?.avatarEmoji ?? '💖';
      });
    }
  }

  void _send(_Action a) {
    _channel?.sendBroadcastMessage(event: 'moment', payload: {'action': a.key});
    _play(a);
  }

  void _onMoment(Map<String, dynamic> payload) {
    _play(_actionByKey(payload['action']?.toString()));
  }

  void _play(_Action a) {
    if (!mounted) return;
    setState(() {
      _moments.add(_Moment(_nextId++, a));
      _close = true;
    });
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _close = false);
    });
  }

  void _remove(int id) {
    if (mounted) setState(() => _moments.removeWhere((m) => m.id == id));
  }

  Future<void> _pickAvatar() async {
    final id = _coupleId;
    if (id == null) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MilesColors.surface1,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              for (final e in _avatarChoices)
                GestureDetector(
                  onTap: () => Navigator.pop(ctx, e),
                  child: Text(e, style: const TextStyle(fontSize: 40)),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null) return;
    await PresenceService.setAvatarEmoji(id, chosen);
    if (mounted) setState(() => _myEmoji = chosen);
  }

  @override
  Widget build(BuildContext context) {
    final partner = ref.watch(sessionProvider).partner;
    final myName = ref.watch(sessionProvider).profile?.displayName ?? 'You';
    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Together'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Choose my avatar',
            icon: const Icon(Icons.face_retouching_natural,
                color: MilesColors.emberSoft),
            onPressed: _pickAvatar,
          ),
        ],
      ),
      body: EmberBackground(
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 8),
              const Text('Tap a gesture — you both feel it.',
                  style: TextStyle(color: MilesColors.taupe, fontSize: 12.5)),
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedAlign(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutBack,
                      alignment:
                          Alignment(_close ? -0.14 : -0.5, 0),
                      child: _Avatar(emoji: _myEmoji, name: myName),
                    ),
                    AnimatedAlign(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutBack,
                      alignment: Alignment(_close ? 0.14 : 0.5, 0),
                      child: _Avatar(
                          emoji: _partnerEmoji,
                          name: partner?.displayName ?? 'Them'),
                    ),
                    for (final m in _moments)
                      _MomentBurst(
                        key: ValueKey(m.id),
                        action: m.action,
                        onDone: () => _remove(m.id),
                      ),
                  ],
                ),
              ),
              // Gesture buttons
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final a in _actions)
                      GestureDetector(
                        onTap: () => _send(a),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: MilesColors.blush.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color: MilesColors.blush.withValues(alpha: 0.4)),
                          ),
                          child: Text('${a.emoji}  ${a.label}',
                              style: const TextStyle(
                                  color: MilesColors.cream50, fontSize: 13)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.emoji, required this.name});
  final String emoji;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 116,
          height: 116,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: MilesColors.surface1,
            border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.3)),
            boxShadow: [
              BoxShadow(
                  color: MilesColors.blush.withValues(alpha: 0.25),
                  blurRadius: 24),
            ],
          ),
          child: Center(child: Text(emoji, style: const TextStyle(fontSize: 58))),
        ),
        const SizedBox(height: 8),
        Text(name,
            style: const TextStyle(color: MilesColors.cream50, fontSize: 13)),
      ],
    );
  }
}

/// The gesture animation: the action emoji blooms between the avatars while a
/// few hearts drift up, then fades.
class _MomentBurst extends StatefulWidget {
  const _MomentBurst({super.key, required this.action, required this.onDone});
  final _Action action;
  final VoidCallback onDone;

  @override
  State<_MomentBurst> createState() => _MomentBurstState();
}

class _MomentBurstState extends State<_MomentBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final v = _c.value;
          final opacity = (1 - v).clamp(0.0, 1.0);
          return Stack(
            alignment: Alignment.center,
            children: [
              // The gesture emoji blooms in the centre.
              Transform.translate(
                offset: Offset(0, -v * 30),
                child: Opacity(
                  opacity: opacity,
                  child: Transform.scale(
                    scale: 0.6 + v * 1.0,
                    child: Text(widget.action.emoji,
                        style: const TextStyle(fontSize: 72)),
                  ),
                ),
              ),
              // A couple of drifting hearts.
              for (var i = 0; i < 3; i++)
                Transform.translate(
                  offset: Offset((i - 1) * 46.0, -v * (90 + i * 20)),
                  child: Opacity(
                    opacity: opacity * 0.9,
                    child: const Text('💕', style: TextStyle(fontSize: 22)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
