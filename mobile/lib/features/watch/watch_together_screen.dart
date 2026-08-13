import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:miles/core/app/session_provider.dart';
import 'package:miles/core/data/supabase_service.dart';
import 'package:miles/core/realtime/realtime_service.dart';
import 'package:miles/core/services/server_clock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/partner_here_badge.dart';
import 'package:miles/features/shell/app_drawer.dart';
import 'package:miles/features/watch/watch_protocol.dart';
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
  Timer? _heartbeat;

  /// Per-sender counter. Identity for every intent this device emits.
  int _seq = 0;

  /// The highest seq seen from the partner, so a duplicated or reordered
  /// delivery is dropped by identity rather than by a wall-clock window.
  int _peerSeq = -1;

  /// Who is driving. Null until anybody acts.
  String? _leader;
  int _leaderSeq = -1;

  bool get _isLeader => _leader != null && _leader == _myUid;

  /// True while a remote intent is being applied, so the controller listener
  /// does not re-broadcast what it was just told.
  ///
  /// Cleared synchronously after the apply, not on a 600ms timer: the old
  /// version both swallowed real gestures inside its window and let stale ones
  /// through outside it.
  bool _applying = false;

  bool _lastPlaying = false;
  int _lastPosMs = 0;

  /// The follower's held correction — playback is paused until this passes.
  DateTime? _holdUntil;

  /// When the partner last told us anything, for stall detection.
  DateTime? _heardAt;
  bool _peerStalled = false;

  @override
  void initState() {
    super.initState();
    _bind(ref.read(sessionProvider));
    _heartbeat = Timer.periodic(kBeatInterval, (_) => _tick());
  }

  /// Subscribe once the couple is known, and re-subscribe if it changes.
  ///
  /// The old build read the session once in initState. On a cold start the
  /// couple resolves asynchronously, so opening this screen first meant
  /// _coupleId was null, the channel was never created, and the screen sat
  /// there looking healthy and synchronising with nobody — permanently, and
  /// with nothing on screen to say so.
  void _bind(SessionState session) {
    final couple = session.couple?.id;
    _myUid = session.profile?.id;
    if (couple == null || couple == _coupleId) return;
    _coupleId = couple;
    _channel?.dispose();
    _channel = ManagedSubscription.start(() => SupabaseService.client
        .channel('watch:$couple', opts: RealtimeChannelConfig(private: true))
        .onBroadcast(event: 'watch', callback: _onMsg)
        .subscribe(),);
    // Ask what is already playing rather than announcing position zero.
    _send(WatchIntent.hello);
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
    if (broadcast) {
      _takeLead();
      _send(WatchIntent.load);
    }
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

  /// A local gesture. Anything the USER did makes this device the leader.
  void _onControllerChange() {
    final c = _controller;
    if (c == null || _applying) return;
    final playing = c.value.isPlaying;
    final pos = c.value.position.inMilliseconds;

    if (playing != _lastPlaying) {
      _lastPlaying = playing;
      _lastPosMs = pos;
      _takeLead();
      _send(playing ? WatchIntent.play : WatchIntent.pause);
      return;
    }

    // A seek shows up as position moving further than wall-clock time could
    // account for. The old build watched isPlaying only, so dragging the
    // scrubber transmitted NOTHING and the two phones simply parted company —
    // while a footer told the user seeking stayed in sync.
    final expected = _lastPosMs + (playing ? kBeatInterval.inMilliseconds : 0);
    if ((pos - expected).abs() > kSeekMs) {
      _lastPosMs = pos;
      _takeLead();
      _send(WatchIntent.seek);
      return;
    }
    _lastPosMs = pos;
  }

  void _takeLead() {
    _leader = _myUid;
    _leaderSeq = _seq + 1;
  }

  /// Emit one intent.
  void _send(WatchIntent intent) {
    final c = _controller;
    final msg = WatchMessage(
      intent: intent,
      from: _myUid ?? '',
      seq: ++_seq,
      // The shared clock, so the other side can work out where this puts it by
      // the time it arrives. DateTime.now() would be this handset's own idea of
      // the time, and these two have been measured seconds apart.
      atMs: ServerClock.now().millisecondsSinceEpoch,
      videoId: _videoId,
      posMs: c?.value.position.inMilliseconds ?? 0,
      playing: c?.value.isPlaying ?? false,
      leader: _leader,
    );
    _channel?.channel
        ?.sendBroadcastMessage(event: 'watch', payload: msg.toJson());
  }

  /// The periodic tick: the leader reports, the follower corrects.
  void _tick() {
    final c = _controller;
    if (c == null || _videoId == null) return;

    if (_isLeader) {
      _send(WatchIntent.beat);
      return;
    }

    // Release a held correction.
    final hold = _holdUntil;
    if (hold != null) {
      if (DateTime.now().isBefore(hold)) return;
      _holdUntil = null;
      if (_lastPlaying) {
        _applying = true;
        c.play();
        _applying = false;
      }
    }

    // The partner has gone quiet mid-playback.
    final heard = _heardAt;
    if (heard != null &&
        _lastPlaying &&
        DateTime.now().difference(heard) > kStallAfter) {
      if (!_peerStalled && mounted) setState(() => _peerStalled = true);
    }
  }

  void _onMsg(Map<String, dynamic> payload) {
    if (!mounted) return;
    final msg = WatchMessage.fromJson(payload);
    if (msg.from.isEmpty || msg.from == _myUid) return;
    // Identity, not a timer. A duplicate or a reordered delivery is dropped
    // because it is old, not because it arrived inside some window.
    if (msg.seq <= _peerSeq) return;
    _peerSeq = msg.seq;
    _heardAt = DateTime.now();
    if (_peerStalled) setState(() => _peerStalled = false);

    // Someone asking what is on. Only the leader answers, and only with what
    // is actually loaded — a newcomer must never be able to reset the film.
    if (msg.intent == WatchIntent.hello) {
      if (_isLeader && _videoId != null) _send(WatchIntent.beat);
      return;
    }

    // Whoever acted most recently drives. Both sides run the same comparison
    // on the same numbers, so they cannot disagree about who that is.
    if (msg.intent != WatchIntent.beat) {
      _leader = leaderBetween(
        a: _myUid ?? '',
        aSeq: _leaderSeq,
        b: msg.from,
        bSeq: msg.seq,
      );
      if (_leader == msg.from) _leaderSeq = msg.seq;
    }
    if (_isLeader && msg.intent == WatchIntent.beat) return;

    final id = msg.videoId;
    if (id != null && id != _videoId) {
      _applying = true;
      _loadVideo(id, broadcast: false);
      _applying = false;
    }

    final c = _controller;
    if (c == null) return;

    _applying = true;
    switch (msg.intent) {
      case WatchIntent.pause:
        _lastPlaying = false;
        c
          ..seekTo(Duration(milliseconds: msg.posMs))
          // seekTo() calls play() unconditionally in this package, so a pause
          // that seeks has to put it back down or the follower resumes on
          // every correction.
          ..pause();
      case WatchIntent.play:
      case WatchIntent.seek:
      case WatchIntent.load:
        _lastPlaying = msg.playing;
        c.seekTo(Duration(milliseconds: msg.projectedPosMs()));
        if (!msg.playing) c.pause();
      case WatchIntent.beat:
        _applyDrift(c, msg);
      case WatchIntent.stall:
        _lastPlaying = false;
        c.pause();
      case WatchIntent.ready:
        if (msg.playing) c.play();
      case WatchIntent.hello:
        break;
    }
    _applying = false;
  }

  /// The follower's correction, and the only place a correction happens.
  ///
  /// Positive drift means this device is AHEAD. Both sides correcting toward
  /// each other is a feedback loop — each acts on the other's stale position
  /// and reports a new one that makes the other act again.
  void _applyDrift(YoutubePlayerController c, WatchMessage msg) {
    if (!msg.playing || !c.value.isPlaying) return;
    final drift = c.value.position.inMilliseconds - msg.projectedPosMs();
    switch (correctionFor(drift)) {
      case WatchCorrection.none:
        break;
      case WatchCorrection.hold:
        // Shed the lead by standing still for exactly it. YouTube's IFrame API
        // rounds unsupported playback rates toward 1.0, so the rate-nudge every
        // other product uses is not available here; a micro-pause sheds the
        // same time and costs no rebuffer.
        if (drift > 0) {
          c.pause();
          _holdUntil =
              DateTime.now().add(Duration(milliseconds: drift.clamp(0, kSeekMs)));
        } else {
          c.seekTo(Duration(milliseconds: msg.projectedPosMs()));
        }
      case WatchCorrection.seek:
        c.seekTo(Duration(milliseconds: msg.projectedPosMs()));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Re-bind rather than reading the session once in initState: on a cold
    // start the couple resolves after this screen is already up.
    ref.listen<SessionState>(sessionProvider, (_, next) => _bind(next));
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
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // Says who is driving, because with one leader that is a real
                  // thing the user can now be told. The old footer asserted
                  // that seeking stayed in sync while the code transmitted no
                  // seek at all.
                  Text(
                    _peerStalled
                        ? '$partnerName is buffering…'
                        : _leader == null
                            ? 'Press play — whoever plays first leads.'
                            : _isLeader
                                ? "You're driving. $partnerName follows."
                                : '$partnerName is driving.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: MilesColors.taupe, fontSize: 12,),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Play, pause and seek carry across. 🍿',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: MilesColors.faint, fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
