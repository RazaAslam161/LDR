import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/chat/chat_input_bar.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();
  final List<Message> _messages = [];
  final Set<String> _ids = {};

  RealtimeChannel? _channel;
  bool _loading = true;

  // Voice recorder
  final _audioRecorder = AudioRecorder();
  final _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final msgs = await ChatRepository.fetch(couple.id);
      _messages.addAll(msgs);
      _ids.addAll(msgs.map((m) => m.id));
    } catch (_) {
      // first-run is fine
    }
    _channel = ChatRepository.subscribe(couple.id, _onIncoming);
    if (mounted) setState(() => _loading = false);
    _scrollToBottom(animate: false);
  }

  void _onIncoming(Message m) {
    if (_ids.contains(m.id)) return;
    _ids.add(m.id);
    if (!mounted) return;
    setState(() => _messages.add(m));
    _scrollToBottom();
  }

  Future<void> _videoCall() async {
    final uri = Uri.parse('https://meet.google.com/new');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No video app found to open.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start a video call.')),
        );
      }
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(target,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _scroll.dispose();
    _audioRecorder.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final couple = session.couple;
    final partnerName = session.partner?.displayName;
    final uid = SupabaseService.currentUserId;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(partnerName ?? 'Chat',
                style: Theme.of(context).textTheme.headlineMedium),
            if (partnerName != null)
              const Text('together, even from here',
                  style: TextStyle(fontSize: 11, color: MilesColors.taupe)),
          ],
        ),
        actions: [
          if (couple != null)
            IconButton(
              tooltip: 'Video call',
              icon: const Icon(Icons.videocam_outlined,
                  color: MilesColors.ember),
              onPressed: _videoCall,
            ),
        ],
      ),
      body: couple == null
          ? const _NotLinked()
          : Column(
              children: [
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _messages.isEmpty
                          ? const _EmptyChat()
                          : ListView.builder(
                              controller: _scroll,
                              padding:
                                  const EdgeInsets.fromLTRB(16, 12, 16, 12),
                              itemCount: _messages.length,
                              itemBuilder: (_, i) {
                                final m = _messages[i];
                                final showTime = i == 0 ||
                                    _messages[i - 1].createdAt.day !=
                                        m.createdAt.day;
                                return _Bubble(
                                  message: m,
                                  mine: m.isMine(uid),
                                  showDateHeader: showTime,
                                  player: _player,
                                );
                              },
                            ),
                ),
                ChatInputBar(
                  coupleId: couple.id,
                  onSendText: (t) => ChatRepository.sendText(couple.id, t),
                  onSendImage: (f) => ChatRepository.sendImage(couple.id, f),
                  onSendVoice: (f) => ChatRepository.sendVoice(couple.id, f),
                ),
              ],
            ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.showDateHeader,
    required this.player,
  });

  final Message message;
  final bool mine;
  final bool showDateHeader;
  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (showDateHeader)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                DateFormat('EEEE, MMM d').format(message.createdAt),
                style:
                    const TextStyle(fontSize: 11, color: MilesColors.faint),
              ),
            ),
          ),
        Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: message.kind == 'text'
                ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
                : const EdgeInsets.all(4),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.74,
            ),
            decoration: BoxDecoration(
              color: mine ? MilesColors.ember : MilesColors.surface1,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(mine ? 18 : 4),
                bottomRight: Radius.circular(mine ? 4 : 18),
              ),
              border: mine
                  ? null
                  : Border.all(color: MilesColors.gilt.withValues(alpha: 0.12)),
            ),
            child: _Content(message: message, player: player),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(
            left: mine ? 0 : 6,
            right: mine ? 6 : 0,
            bottom: 4,
          ),
          child: Text(
            DateFormat('h:mm a').format(message.createdAt),
            style: const TextStyle(fontSize: 10, color: MilesColors.faint),
          ),
        ),
      ],
    );
  }
}

/// Renders the inside of a bubble based on message kind.
class _Content extends StatelessWidget {
  const _Content({required this.message, required this.player});
  final Message message;
  final AudioPlayer player;

  @override
  Widget build(BuildContext context) {
    final m = message;
    switch (m.kind) {
      case 'image':
        final url = m.imageUrl;
        if (url == null) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text('📷 image unavailable',
                style: TextStyle(color: MilesColors.cream50, fontSize: 14)),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.network(
            url,
            width: 220,
            fit: BoxFit.cover,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const SizedBox(
                    width: 220,
                    height: 140,
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
            errorBuilder: (_, __, ___) => const Padding(
              padding: EdgeInsets.all(12),
              child: Text('📷 could not load',
                  style: TextStyle(color: MilesColors.cream50, fontSize: 14)),
            ),
          ),
        );
      case 'voice':
        final url = m.voiceUrl;
        if (url == null) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text('🎙️ voice unavailable',
                style: TextStyle(color: MilesColors.cream50, fontSize: 14)),
          );
        }
        return _VoicePlayer(url: url, player: player);
      default:
        return Text(
          m.body ?? '',
          style: const TextStyle(
            color: MilesColors.cream50,
            fontSize: 15,
            height: 1.35,
          ),
        );
    }
  }
}

class _VoicePlayer extends StatefulWidget {
  const _VoicePlayer({required this.url, required this.player});
  final String url;
  final AudioPlayer player;

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    widget.player.playerStateStream.listen((state) {
      final playing = state.processingState != ProcessingState.completed &&
          state.playing;
      if (playing != _playing) {
        if (mounted) setState(() => _playing = playing);
      }
    });
  }

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await widget.player.pause();
      } else {
        await widget.player.setUrl(widget.url);
        await widget.player.play();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play voice note.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: MilesColors.cream50.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: MilesColors.cream50,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Pseudo-waveform (visual only)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            18,
            (i) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              width: 2.5,
              height: 8 + ((i * 7) % 18).toDouble(),
              decoration: BoxDecoration(
                color: MilesColors.cream50.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('💌', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 16),
            Text('Say something sweet',
                style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 8),
            const Text(
              'This is your private space — just the two of you. '
              'Send the first message, snap a photo, or hold the mic to talk.',
              textAlign: TextAlign.center,
              style: TextStyle(color: MilesColors.taupe, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotLinked extends StatelessWidget {
  const _NotLinked();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Link with your partner first to start chatting.',
          textAlign: TextAlign.center,
          style: TextStyle(color: MilesColors.taupe),
        ),
      ),
    );
  }
}
