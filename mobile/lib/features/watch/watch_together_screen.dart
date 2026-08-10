import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

/// Watch & listen together — paste a YouTube link (movie, music video, playlist)
/// and play/pause/seek stay loosely synced on both phones via a broadcast
/// channel. Whoever touches the controls drives; the other follows.
class WatchTogetherScreen extends ConsumerStatefulWidget {
  const WatchTogetherScreen({super.key});

  @override
  ConsumerState<WatchTogetherScreen> createState() =>
      _WatchTogetherScreenState();
}

class _WatchTogetherScreenState extends ConsumerState<WatchTogetherScreen> {
  YoutubePlayerController? _controller;
  ManagedSubscription? _channel;
  final _urlInput = TextEditingController();
  String? _coupleId;
  String? _myUid;
  String? _videoId;
  bool _applyingRemote = false;
  bool _lastPlaying = false;
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    _coupleId = session.couple?.id;
    _myUid = session.profile?.id;
    if (_coupleId != null) {
      _channel = ManagedSubscription.start(() => SupabaseService.client
          .channel('watch:${_coupleId!}', opts: RealtimeChannelConfig(private: true))
          .onBroadcast(event: 'watch', callback: _onMsg)
          .subscribe(),);
    }
    _heartbeat = Timer.periodic(
        const Duration(milliseconds: 2500), (_) => _broadcast(),);
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _channel?.dispose();
    _controller?.dispose();
    _urlInput.dispose();
    super.dispose();
  }

  void _loadVideo(String id, {bool broadcast = true}) {
    _videoId = id;
    if (_controller == null) {
      _controller = YoutubePlayerController(
        initialVideoId: id,
      )..addListener(_onControllerChange);
      setState(() {});
    } else {
      _controller!.load(id);
    }
    if (broadcast) _broadcast();
  }

  /// Paste the clipboard link and play it (robust against the paste menu not
  /// showing on some keyboards).
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _urlInput.text = text;
    final id = YoutubePlayer.convertUrlToId(text);
    if (id != null) {
      _loadVideo(id);
      _urlInput.clear();
      if (mounted) FocusScope.of(context).unfocus();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clipboard isn’t a YouTube link.')),
      );
    }
  }

  void _onUrlSubmit() {
    final id = YoutubePlayer.convertUrlToId(_urlInput.text.trim());
    if (id != null) {
      _loadVideo(id);
      _urlInput.clear();
      FocusScope.of(context).unfocus();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("That doesn't look like a YouTube link.")),
      );
    }
  }

  void _onControllerChange() {
    final c = _controller;
    if (c == null || _applyingRemote) return;
    if (c.value.isPlaying != _lastPlaying) {
      _lastPlaying = c.value.isPlaying;
      _broadcast(); // play/pause toggled locally — push it
    }
  }

  void _broadcast() {
    final c = _controller;
    final id = _videoId;
    if (c == null || id == null || _applyingRemote) return;
    _channel?.channel?.sendBroadcastMessage(event: 'watch', payload: {
      'from': _myUid,
      'videoId': id,
      'playing': c.value.isPlaying,
      'pos': c.value.position.inMilliseconds,
    },);
  }

  void _onMsg(Map<String, dynamic> payload) {
    if (!mounted || payload['from'] == _myUid) return;
    final id = payload['videoId']?.toString();
    final playing = payload['playing'] == true;
    final pos = (payload['pos'] as num?)?.toInt() ?? 0;
    if (id == null) return;
    _applyingRemote = true;
    if (id != _videoId) {
      _loadVideo(id, broadcast: false);
    }
    final c = _controller;
    if (c != null) {
      final drift = (c.value.position.inMilliseconds - pos).abs();
      if (drift > 2500) c.seekTo(Duration(milliseconds: pos));
      if (playing && !c.value.isPlaying) c.play();
      if (!playing && c.value.isPlaying) c.pause();
      _lastPlaying = playing;
    }
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _applyingRemote = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final partnerName =
        ref.watch(sessionProvider).partner?.displayName ?? 'them';
    final controller = _controller;
    return Scaffold(
      backgroundColor: MilesColors.night,
      drawer: const AppDrawer(),
      appBar: AppBar(
        actions: const [PartnerHereAction()],
        title: const Text('Watch Together'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlInput,
                    style: const TextStyle(color: MilesColors.cream50),
                    decoration: const InputDecoration(
                      hintText: 'Paste a YouTube link…',
                      prefixIcon:
                          Icon(Icons.link, color: MilesColors.taupe, size: 20),
                    ),
                    onSubmitted: (_) => _onUrlSubmit(),
                  ),
                ),
                IconButton(
                  tooltip: 'Paste link',
                  icon: const Icon(Icons.content_paste,
                      color: MilesColors.emberSoft,),
                  onPressed: _paste,
                ),
                FilledButton(
                    onPressed: _onUrlSubmit, child: const Text('Play'),),
              ],
            ),
          ),
          if (controller != null)
            YoutubePlayer(
              controller: controller,
              showVideoProgressIndicator: true,
              progressIndicatorColor: MilesColors.ember,
            )
          else
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Paste a YouTube link and press Play —\n'
                    'you and $partnerName watch it in sync.',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: MilesColors.taupe, fontSize: 13),
                  ),
                ),
              ),
            ),
          if (controller != null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Play, pause, and seek stay in sync on both phones. 🍿',
                textAlign: TextAlign.center,
                style: TextStyle(color: MilesColors.taupe, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
