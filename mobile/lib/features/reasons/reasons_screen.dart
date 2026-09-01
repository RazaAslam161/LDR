import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/ember_background.dart';
import 'package:miles/core/widgets/ember_press.dart';
import 'package:miles/features/auth/auth_errors.dart';
import 'package:miles/features/reasons/reasons_repository.dart';
import 'package:miles/features/shell/app_drawer.dart';

/// A jar of "reasons I love you" — both add notes; one is featured each day.
class ReasonsScreen extends ConsumerStatefulWidget {
  const ReasonsScreen({super.key});

  @override
  ConsumerState<ReasonsScreen> createState() => _ReasonsScreenState();
}

class _ReasonsScreenState extends ConsumerState<ReasonsScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<LoveReason> _reasons = const [];
  bool _loading = true;
  bool _adding = false;
  String? _loadError;
  String? _coupleId;
  String? _myUid;
  ManagedSubscription? _channel;

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    _coupleId = session.couple?.id;
    _myUid = session.profile?.id;
    if (_coupleId != null) {
      _channel = ManagedSubscription.start(
          () => ReasonsRepository.subscribe(_coupleId!, _load),);
    }
    _load();
  }

  @override
  void dispose() {
    _channel?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = _coupleId;
    if (id == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final r = await ReasonsRepository.list(id);
      if (mounted) {
        setState(() {
          _reasons = r;
          _loadError = null;
          _loading = false;
        });
      }
    } catch (e) {
      // Falling through to _loading = false alone rendered the "add the first
      // reason" empty state, so a failed list read looked like an empty jar.
      if (mounted) {
        setState(() {
          _loadError = friendlyAuthError(e);
          _loading = false;
        });
      }
    }
  }

  void _toast(String m, {VoidCallback? onRetry}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(m),
        action: onRetry == null
            ? null
            : SnackBarAction(label: 'Retry', onPressed: onRetry),
      ),
    );
  }

  Future<void> _delete(LoveReason r) async {
    try {
      await ReasonsRepository.delete(r.id);
      await _load();
    } catch (_) {
      // This ran uncaught inside the tile's onTap, so a failed delete left the
      // row on screen with nothing said and only a console-level error.
      _toast("That didn't delete.", onRetry: () => _delete(r));
    }
  }

  /// A stable "reason of the day" — same one all day, rotates daily.
  LoveReason? get _featured {
    if (_reasons.isEmpty) return null;
    final now = DateTime.now();
    final dayOfYear =
        now.difference(DateTime(now.year)).inDays; // 0..365
    return _reasons[dayOfYear % _reasons.length];
  }

  Future<void> _add() async {
    final text = _input.text.trim();
    final id = _coupleId;
    final uid = _myUid;
    if (text.isEmpty || id == null || uid == null) return;
    setState(() => _adding = true);
    try {
      await ReasonsRepository.add(coupleId: id, author: uid, text: text);
      _input.clear();
      await _load();
    } catch (_) {
      // _input is only cleared after the write returns, so the text survives a
      // failure — but silently, which read as the send button doing nothing.
      _toast("That didn't send — it's still in the box, try again.");
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final partnerName =
        ref.watch(sessionProvider).partner?.displayName ?? 'them';
    final featured = _featured;
    return Scaffold(
      backgroundColor: Colors.transparent,
      drawer: const AppDrawer(),
      appBar: AppBar(
        
        title: const Text('Reasons I Love You'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      body: EmberBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (featured != null) _FeaturedCard(reason: featured, myUid: _myUid),
                    Expanded(
                      child: _loadError != null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_loadError!,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: MilesColors.taupe,
                                            fontSize: 13,
                                            height: 1.5,),),
                                    const SizedBox(height: 14),
                                    TextButton(
                                        onPressed: _load,
                                        child: const Text('Try again'),),
                                  ],
                                ),
                              ),
                            )
                          : _reasons.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Image.asset('assets/art/lantern.webp',
                                        width: 120, height: 120,),
                                    const SizedBox(height: 12),
                                    Text(
                                      'Add the first reason you love '
                                      '$partnerName.\nOne shows up here '
                                      'each day.',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: MilesColors.taupe,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : ListView.separated(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                              itemCount: _reasons.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, i) {
                                final r = _reasons[i];
                                final mine = r.author == _myUid;
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12,),
                                  decoration: BoxDecoration(
                                    color: MilesColors.surface1,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Row(
                                    children: [
                                      Text(mine ? '💗' : '💛',
                                          style: const TextStyle(fontSize: 16),),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(r.text,
                                            style: const TextStyle(
                                                color: MilesColors.cream50,
                                                fontSize: 14,
                                                height: 1.3,),),
                                      ),
                                      if (mine)
                                        GestureDetector(
                                          onTap: () => _delete(r),
                                          child: const Padding(
                                            padding: EdgeInsets.only(left: 8),
                                            child: Icon(Icons.close,
                                                size: 16,
                                                color: MilesColors.taupe,),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    _inputBar,
                  ],
                ),
        ),
      ),
    );
  }

  Widget get _inputBar => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 3,
                  style: const TextStyle(color: MilesColors.cream50),
                  decoration: const InputDecoration(
                    hintText: 'Another reason you love them…',
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              EmberPress(
                onTap: _adding ? null : _add,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: MilesGradients.cta,
                  ),
                  child: _adding
                      ? const Padding(
                          padding: EdgeInsets.all(13),
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white,),
                        )
                      : const Icon(Icons.add, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
}

class _FeaturedCard extends StatelessWidget {
  const _FeaturedCard({required this.reason, required this.myUid});
  final LoveReason reason;
  final String? myUid;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: [
            MilesColors.ember.withValues(alpha: 0.25),
            MilesColors.blush.withValues(alpha: 0.18),
          ],
        ),
        border: Border.all(color: MilesColors.gilt.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('TODAY’S REASON',
              style: TextStyle(
                  color: MilesColors.gilt,
                  fontSize: 10,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,),),
          const SizedBox(height: 8),
          Text('“${reason.text}”',
              style: const TextStyle(
                  color: MilesColors.cream50,
                  fontSize: 18,
                  height: 1.4,
                  fontWeight: FontWeight.w500,),),
        ],
      ),
    );
  }
}
