import 'dart:async';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/core/mood.dart';
import 'package:miles/core/root_scaffold_key.dart';
import 'package:miles/core/services/presence_service.dart';
import 'package:miles/core/session_provider.dart';
import 'package:miles/core/supabase_service.dart';
import 'package:miles/core/theme.dart';
import 'package:miles/features/chat/chat_input_bar.dart';
import 'package:miles/features/chat/chat_repository.dart';
import 'package:miles/features/chat/mood_selector.dart';
import 'package:miles/features/chat/typing_indicator.dart';
import 'package:miles/features/closer/secure_screen.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Presence;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

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
  String? _coupleId;
  Timer? _typingTimer;
  bool _typingActive = false;
  bool _hasNewMessage = false;
  Message? _replyingTo;

  void _startReply(Message m) {
    if (m.deletedForEveryone) return;
    setState(() => _replyingTo = m);
  }

  void _cancelReply() => setState(() => _replyingTo = null);

  /// The id to attach to the next send (and clears the reply state).
  String? _takeReplyId() {
    final id = _replyingTo?.id;
    if (_replyingTo != null) setState(() => _replyingTo = null);
    return id;
  }

  /// Find a loaded message by id (for rendering a quoted reply preview).
  Message? _byId(String? id) {
    if (id == null) return null;
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  // Voice recorder
  final _audioRecorder = AudioRecorder();
  final _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _init();
  }

  void _onScroll() {
    if (_hasNewMessage && _isAtBottom()) {
      setState(() => _hasNewMessage = false);
    }
  }

  Future<void> _init() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _coupleId = couple.id;
    try {
      final msgs = await ChatRepository.fetch(couple.id);
      _messages.addAll(msgs);
      _sortMessages();
      _ids.addAll(msgs.map((m) => m.id));
    } catch (_) {
      // first-run is fine
    }
    _channel = ChatRepository.subscribe(couple.id, _onIncoming);
    PresenceService.setOnline(couple.id, online: true);
    PresenceService.setTypingInChat(couple.id, inChat: true);
    if (mounted) setState(() => _loading = false);
    // reverse:true already pins the view to the newest message — no scroll needed.
  }

  void _onIncoming(Message m) {
    if (_ids.contains(m.id)) return;
    _ids.add(m.id);
    if (!mounted) return;
    final mine = m.isMine(SupabaseService.currentUserId);
    final atBottom = _isAtBottom();
    setState(() {
      _messages.insert(0, m); // newest-first ordering
      _sortMessages();
    });
    // Don't yank a user who's reading history; show a chip instead.
    if (mine || atBottom) {
      _scrollToNewest();
    } else {
      setState(() => _hasNewMessage = true);
    }
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

  void _sortMessages() {
    // Newest first; id as a stable tiebreaker for same-second messages.
    _messages.sort((a, b) {
      final c = b.createdAt.compareTo(a.createdAt);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
  }

  /// With reverse:true the newest message sits at offset 0 (the visual bottom).
  bool _isAtBottom() {
    if (!_scroll.hasClients) return true;
    return _scroll.offset <= _scroll.position.minScrollExtent + 120;
  }

  void _scrollToNewest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.minScrollExtent; // 0 = newest (reverse:true)
      if (animate) {
        _scroll.animateTo(target,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  void _onTyping(String _) {
    final id = _coupleId;
    if (id == null) return;
    if (!_typingActive) {
      _typingActive = true;
      PresenceService.setTyping(id, typing: true);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(milliseconds: 1500), () {
      _typingActive = false;
      PresenceService.setTyping(id, typing: false);
    });
  }

  Future<void> _setMyMood() async {
    final id = _coupleId;
    if (id == null) return;
    final m = await showMoodSelector(context);
    if (m == null) return;
    await PresenceService.setMood(id, m.key, m.hex);
  }

  Future<void> _reload() async {
    final couple = ref.read(sessionProvider).couple;
    if (couple == null) return;
    try {
      final msgs = await ChatRepository.fetch(couple.id);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(msgs);
        _sortMessages();
        _ids
          ..clear()
          ..addAll(msgs.map((m) => m.id));
      });
    } catch (_) {}
  }

  Future<void> _showMessageActions(Message m, bool mine) async {
    if (m.deletedForEveryone) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MilesColors.surface1,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply, color: MilesColors.emberSoft),
              title: const Text('Reply',
                  style: TextStyle(color: MilesColors.cream50)),
              onTap: () => Navigator.pop(ctx, 'reply'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.visibility_off, color: MilesColors.taupe),
              title: const Text('Delete for me',
                  style: TextStyle(color: MilesColors.cream50)),
              onTap: () => Navigator.pop(ctx, 'me'),
            ),
            if (mine)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Color(0xFFB83A57)),
                title: const Text('Delete for everyone',
                    style: TextStyle(color: Color(0xFFB83A57))),
                onTap: () => Navigator.pop(ctx, 'everyone'),
              ),
            ListTile(
              leading: const Icon(Icons.close, color: MilesColors.faint),
              title: const Text('Cancel',
                  style: TextStyle(color: MilesColors.taupe)),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'reply') {
      _startReply(m);
      return;
    }
    try {
      if (action == 'me') {
        await ChatRepository.deleteForMe(m.id);
      } else {
        await ChatRepository.deleteForEveryone(m.id);
      }
      await _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not delete that message.')));
      }
    }
  }

  Future<void> _clearConversation() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MilesColors.surface1,
        title: const Text('Clear conversation?'),
        content: const Text(
          "This deletes all messages for you only. Your partner's chat history "
          "won't be affected.",
          style: TextStyle(color: MilesColors.taupe, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ChatRepository.clearConversation();
      await _reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not clear the conversation.')));
      }
    }
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    final id = _coupleId;
    if (id != null) {
      PresenceService.setTyping(id, typing: false);
      PresenceService.setTypingInChat(id, inChat: false);
    }
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
    final presence = ref.watch(partnerPresenceProvider);
    final partnerMood = moodByKey(presence?.currentMood);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(partnerName ?? 'Chat',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineMedium),
                ),
                if (partnerMood != null) ...[
                  const SizedBox(width: 8),
                  Text(partnerMood.emoji,
                      style: const TextStyle(fontSize: 16)),
                ],
              ],
            ),
            if (partnerName != null) _ChatSubtitle(presence: presence),
          ],
        ),
        actions: [
          if (couple != null)
            IconButton(
              tooltip: 'Set your mood',
              icon:
                  const Icon(Icons.palette_outlined, color: MilesColors.gilt),
              onPressed: _setMyMood,
            ),
          if (couple != null)
            IconButton(
              tooltip: 'Video call',
              icon: const Icon(Icons.videocam_outlined,
                  color: MilesColors.ember),
              onPressed: _videoCall,
            ),
          if (couple != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: MilesColors.gilt),
              color: MilesColors.surface1,
              onSelected: (v) {
                if (v == 'clear') _clearConversation();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'clear', child: Text('Clear conversation')),
              ],
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
                          : Builder(builder: (_) {
                              final visible = _messages
                                  .where((m) => !m.isHiddenFor(uid))
                                  .toList();
                              if (visible.isEmpty) return const _EmptyChat();
                              return Stack(
                                children: [
                                  ListView.builder(
                                    controller: _scroll,
                                    reverse: true,
                                    padding: const EdgeInsets.fromLTRB(
                                        16, 12, 16, 12),
                                    itemCount: visible.length,
                                    itemBuilder: (_, i) {
                                      final m = visible[i];
                                      // Descending list: the older neighbour is
                                      // i+1, so a date header marks the oldest
                                      // message of each day (top of the group).
                                      final showTime = i == visible.length - 1 ||
                                          !DateUtils.isSameDay(
                                              visible[i + 1].createdAt,
                                              m.createdAt);
                                      return GestureDetector(
                                        onLongPress: () => _showMessageActions(
                                            m, m.isMine(uid)),
                                        child: _Bubble(
                                          message: m,
                                          mine: m.isMine(uid),
                                          showDateHeader: showTime,
                                          repliedTo: _byId(m.replyToId),
                                          player: _player,
                                        ),
                                      );
                                    },
                                  ),
                                  if (_hasNewMessage)
                                    Positioned(
                                      bottom: 12,
                                      left: 0,
                                      right: 0,
                                      child: Center(
                                        child: _NewMessageChip(
                                          onTap: () {
                                            setState(
                                                () => _hasNewMessage = false);
                                            _scrollToNewest();
                                          },
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            }),
                ),
                ChatInputBar(
                  coupleId: couple.id,
                  onChanged: _onTyping,
                  replyingTo: _replyingTo,
                  onCancelReply: _cancelReply,
                  onSendText: (t) =>
                      ChatRepository.sendText(couple.id, t, replyToId: _takeReplyId()),
                  onSendImage: (f) =>
                      ChatRepository.sendImage(couple.id, f, replyToId: _takeReplyId()),
                  onSendVoice: (f) =>
                      ChatRepository.sendVoice(couple.id, f, replyToId: _takeReplyId()),
                  onSendVideo: (f) =>
                      ChatRepository.sendVideo(couple.id, f, replyToId: _takeReplyId()),
                ),
              ],
            ),
    );
  }
}

/// Presence-aware AppBar subtitle: typing… / Online / Last seen.
class _ChatSubtitle extends StatelessWidget {
  const _ChatSubtitle({required this.presence});
  final Presence? presence;

  @override
  Widget build(BuildContext context) {
    final p = presence;
    if (p == null) {
      return const Text('together, even from here',
          style: TextStyle(fontSize: 11, color: MilesColors.taupe));
    }
    if (p.isTyping && p.typingInChat) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('typing',
              style: TextStyle(fontSize: 11, color: MilesColors.sage)),
          SizedBox(width: 6),
          TypingIndicator(),
        ],
      );
    }
    if (p.isOnline) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Dot(color: MilesColors.sage),
          SizedBox(width: 6),
          Text('Online',
              style: TextStyle(fontSize: 11, color: MilesColors.sage)),
        ],
      );
    }
    final seen = p.lastSeen;
    return Text(
      seen == null ? 'Offline' : 'Last seen ${_ago(seen)}',
      style: const TextStyle(fontSize: 11, color: MilesColors.taupe),
    );
  }

  static String _ago(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('MMM d').format(d);
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.showDateHeader,
    required this.player,
    this.repliedTo,
  });

  final Message message;
  final bool mine;
  final bool showDateHeader;
  final AudioPlayer player;
  final Message? repliedTo;

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (repliedTo != null) _ReplyPreview(message: repliedTo!),
                message.deletedForEveryone
                    ? const Text(
                        'This message was deleted',
                        style: TextStyle(
                            color: MilesColors.cream50,
                            fontStyle: FontStyle.italic,
                            fontSize: 14),
                      )
                    : _Content(message: message, player: player),
              ],
            ),
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

/// Small quoted preview shown at the top of a bubble that's replying.
class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: MilesColors.gilt, width: 3),
        ),
      ),
      child: Text(
        message.previewText(),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
            color: MilesColors.cream50, fontSize: 12, height: 1.2),
      ),
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
      case 'video':
        return _VideoBubble(path: m.videoPath);
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

/// "↓ New message" pill shown when a message arrives while the user is scrolled
/// up reading history — taps to jump to the newest.
class _NewMessageChip extends StatelessWidget {
  const _NewMessageChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: MilesColors.ember,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: MilesColors.ember.withValues(alpha: 0.4),
                blurRadius: 12,
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward, size: 16, color: MilesColors.cream50),
              SizedBox(width: 6),
              Text('New message',
                  style: TextStyle(color: MilesColors.cream50, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tap-to-play thumbnail for a private video message → full-screen player.
class _VideoBubble extends StatefulWidget {
  const _VideoBubble({required this.path});
  final String? path;

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  bool _loading = false;

  Future<void> _open() async {
    if (widget.path == null) return;
    setState(() => _loading = true);
    final url = await ChatRepository.signedVideoUrl(widget.path);
    if (!mounted) return;
    setState(() => _loading = false);
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video unavailable')));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _FullScreenVideo(url: url)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _loading ? null : _open,
      child: Container(
        width: 220,
        height: 140,
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: _loading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: MilesColors.blush),
                  child: const Icon(Icons.play_arrow,
                      color: MilesColors.cream50, size: 30),
                ),
        ),
      ),
    );
  }
}

/// Full-screen player with FLAG_SECURE so intimate video can't be
/// screenshotted / screen-recorded / shown in the recents preview.
class _FullScreenVideo extends StatefulWidget {
  const _FullScreenVideo({required this.url});
  final String url;

  @override
  State<_FullScreenVideo> createState() => _FullScreenVideoState();
}

class _FullScreenVideoState extends State<_FullScreenVideo> {
  VideoPlayerController? _vp;
  ChewieController? _chewie;

  @override
  void initState() {
    super.initState();
    SecureScreen.setSecure();
    _init();
  }

  Future<void> _init() async {
    final vp = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await vp.initialize();
    } catch (_) {
      await vp.dispose();
      return;
    }
    if (!mounted) {
      await vp.dispose();
      return;
    }
    setState(() {
      _vp = vp;
      _chewie = ChewieController(
        videoPlayerController: vp,
        autoPlay: true,
        looping: false,
        aspectRatio:
            vp.value.aspectRatio == 0 ? 16 / 9 : vp.value.aspectRatio,
      );
    });
  }

  @override
  void dispose() {
    SecureScreen.clearSecure();
    _chewie?.dispose();
    _vp?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: const BackButton(color: Colors.white),
      ),
      body: Center(
        child: _chewie == null
            ? const CircularProgressIndicator()
            : Chewie(controller: _chewie!),
      ),
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
