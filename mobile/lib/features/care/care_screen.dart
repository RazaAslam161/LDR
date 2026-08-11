import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/features/care/care_repository.dart';
import 'package:miles/features/shell/app_drawer.dart';

class _Preset {
  const _Preset(this.kind, this.emoji, this.label, this.message);
  final String kind;
  final String emoji;
  final String label;
  final String message;
}

const List<_Preset> _presets = [
  _Preset('eat', '🥗', 'Lunch', 'Did you have lunch yet? 🥗'),
  _Preset('eat', '🍲', 'Dinner', 'Time for dinner 🍲'),
  _Preset('eat', '🍳', 'Breakfast', 'Don’t skip breakfast 🍳'),
  _Preset('medicine', '💊', 'Medicine', 'Take your medicine 💊'),
  _Preset('water', '💧', 'Water', 'Drink some water 💧'),
  _Preset('sleep', '😴', 'Sleep', 'Go to sleep, love 😴'),
  _Preset('break', '☕', 'Break', 'Take a little break ☕'),
  _Preset('move', '🚶', 'Stretch', 'Get up and stretch 🚶'),
];

/// Send your partner a gentle reminder; they tap "Done" so you know they did it.
class CareScreen extends ConsumerStatefulWidget {
  const CareScreen({super.key});

  @override
  ConsumerState<CareScreen> createState() => _CareScreenState();
}

class _CareScreenState extends ConsumerState<CareScreen> {
  String? _coupleId;
  String? _myUid;
  ManagedSubscription? _channel;
  List<CareNudge> _nudges = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    _coupleId = session.couple?.id;
    _myUid = session.profile?.id;
    if (_coupleId != null) {
      _channel = ManagedSubscription.start(
          () => CareRepository.subscribe(_coupleId!, _load),);
    }
    _load();
  }

  @override
  void dispose() {
    _channel?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = _coupleId;
    if (id == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final n = await CareRepository.list(id);
      if (mounted) {
        setState(() {
        _nudges = n;
        _loading = false;
      });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send(String kind, String message) async {
    final id = _coupleId;
    final uid = _myUid;
    if (id == null || uid == null) return;
    try {
      await CareRepository.send(
          coupleId: id, fromUser: uid, kind: kind, message: message,);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Reminder sent 💛')),
        );
      }
      await _load();
    } catch (_) {}
  }

  Future<void> _custom() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Custom reminder',
            style: TextStyle(color: MilesColors.cream50),),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: MilesColors.cream50),
          decoration: const InputDecoration(hintText: 'e.g. Call your mom 💛'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Send'),),
        ],
      ),
    );
    if (text != null && text.isNotEmpty) await _send('custom', text);
  }

  @override
  Widget build(BuildContext context) {
    final partnerName =
        ref.watch(sessionProvider).partner?.displayName ?? 'them';
    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: const AppDrawer(),
      appBar: AppBar(
        actions: const [PartnerHereAction()],
        title: const Text('Care Reminders'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      body: EmberBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Send $partnerName a little nudge to take care.',
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 12.5,),),
              ),
              // Preset grid
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final p in _presets)
                      GestureDetector(
                        onTap: () => _send(p.kind, p.message),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10,),
                          decoration: BoxDecoration(
                            color: MilesColors.surface1,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: MilesColors.gilt.withValues(alpha: 0.2),),
                          ),
                          child: Text('${p.emoji}  ${p.label}',
                              style: const TextStyle(
                                  color: MilesColors.cream50, fontSize: 13,),),
                        ),
                      ),
                    GestureDetector(
                      onTap: _custom,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10,),
                        decoration: BoxDecoration(
                          color: MilesColors.tint(MilesColors.blush, 0.16),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: MilesColors.blush.withValues(alpha: 0.4),),
                        ),
                        child: const Text('✏️  Custom',
                            style: TextStyle(
                                color: MilesColors.cream50, fontSize: 13,),),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: MilesColors.surface2, height: 16),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _nudges.isEmpty
                        ? const Center(
                            child: Text('No reminders yet.',
                                style: TextStyle(color: MilesColors.taupe),),)
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            itemCount: _nudges.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, i) =>
                                _nudgeTile(_nudges[i]),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nudgeTile(CareNudge n) {
    final mine = n.isMine(_myUid);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: MilesColors.surface1,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.message,
                    style: const TextStyle(
                        color: MilesColors.cream50, fontSize: 14,),),
                const SizedBox(height: 2),
                Text(
                  mine
                      ? (n.acknowledged ? 'They did it ✓' : 'You sent this')
                      : (n.acknowledged ? 'You marked done ✓' : 'For you'),
                  style: TextStyle(
                      color: n.acknowledged
                          ? MilesColors.sage
                          : MilesColors.taupe,
                      fontSize: 11,),
                ),
              ],
            ),
          ),
          // The recipient (not me) can mark it done.
          if (!mine && !n.acknowledged)
            GestureDetector(
              onTap: () async {
                await CareRepository.acknowledge(n.id);
                await _load();
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: MilesColors.tint(MilesColors.sage, 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Done ✅',
                    style: TextStyle(color: MilesColors.cream50, fontSize: 12),),
              ),
            ),
        ],
      ),
    );
  }
}
