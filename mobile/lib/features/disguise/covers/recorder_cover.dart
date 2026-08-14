import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:miles/features/disguise/cover_gate.dart';
import 'package:miles/features/disguise/covers/cover_theme.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// A voice recorder that genuinely records.
///
/// The library starts empty, and an empty recorder is the one empty screen
/// nobody finds odd — an empty photo gallery invites questions, an app you
/// never got round to using does not. It is also the lowest-curiosity icon on a
/// home screen: there is no reason to open someone else's recorder, and if you
/// do, an empty list ends the visit in a second.
///
/// Recordings live in the cache directory and are capped, deliberately: a cover
/// that can accumulate hours of a stranger's audio is a liability the disguise
/// was supposed to remove, not add.
///
/// Side benefit worth having: it normalises the Android 12+ green microphone
/// indicator on this handset, so the indicator appearing during a real voice
/// note is no longer the anomaly it would otherwise be.
///
/// **The way in: hold the 00:00 readout before recording anything.** Normal use
/// is tapping the record button — the readout is a passive number with no
/// ripple, no tap handler and no affordance, and the gate only opens while it
/// literally reads zero, so it cannot be reached mid-recording.
class RecorderCover extends StatefulWidget {
  const RecorderCover({required this.onAuthenticated, super.key});

  final VoidCallback onAuthenticated;

  @override
  State<RecorderCover> createState() => _RecorderCoverState();
}

class _RecorderCoverState extends State<RecorderCover>
    with CoverGate<RecorderCover> {
  /// Both caps exist so the cover cannot quietly become a pile of someone's
  /// audio. Five minutes is longer than any voice memo anybody actually makes.
  static const _maxFiles = 20;
  static const _maxLength = Duration(minutes: 5);

  final _recorder = AudioRecorder();
  final _player = AudioPlayer();

  List<_Clip> _clips = [];
  bool _loaded = false;

  bool _recording = false;
  Duration _elapsed = Duration.zero;
  DateTime? _startedAt;
  String? _path;
  Timer? _tick;
  StreamSubscription<Amplitude>? _amplitude;
  final List<double> _levels = [];

  String? _playing;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted) {
        setState(() => _playing = null);
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_amplitude?.cancel());
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  void onCoverUnlocked() => widget.onAuthenticated();

  // ── Library ────────────────────────────────────────────────────────────────

  Future<Directory> _dir() async {
    final base = await getTemporaryDirectory();
    return Directory('${base.path}/recordings')..createSync(recursive: true);
  }

  Future<void> _load() async {
    var clips = <_Clip>[];
    try {
      final dir = await _dir();
      clips = dir
          .listSync()
          .whereType<File>()
          .map(_Clip.fromFile)
          .whereType<_Clip>()
          .toList()
        ..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    } catch (_) {
      // No cache directory on this device, or no platform channel at all — an
      // empty library is still a working recorder, and a cover that shows an
      // error where its list should be is a cover that gets looked at twice.
    }
    if (!mounted) return;
    setState(() {
      _clips = clips;
      _loaded = true;
    });
  }

  Future<void> _delete(_Clip clip) async {
    if (_playing == clip.path) {
      await _player.stop();
      if (mounted) setState(() => _playing = null);
    }
    try {
      File(clip.path).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
    if (mounted) setState(() => _clips.remove(clip));
  }

  // ── Recording ──────────────────────────────────────────────────────────────

  Future<void> _toggleRecording() async {
    HapticFeedback.selectionClick();
    if (_recording) {
      await _stop();
      return;
    }
    if (!await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied.')),
        );
      }
      return;
    }
    if (_clips.length >= _maxFiles) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Delete a recording to make room.')),
        );
      }
      return;
    }
    await _player.stop();

    final dir = await _dir();
    final started = DateTime.now();
    final path = '${dir.path}/rec_${started.millisecondsSinceEpoch}.m4a';
    try {
      await _recorder.start(const RecordConfig(bitRate: 96000), path: path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start recording.')),
        );
      }
      return;
    }

    _amplitude = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen(_onAmplitude);
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final elapsed = DateTime.now().difference(started);
      if (elapsed >= _maxLength) {
        unawaited(_stop());
        return;
      }
      setState(() => _elapsed = elapsed);
    });
    if (!mounted) return;
    setState(() {
      _recording = true;
      _playing = null;
      _startedAt = started;
      _path = path;
      _elapsed = Duration.zero;
      _levels.clear();
    });
  }

  /// dBFS in, 0..1 out. The floor is -45 rather than the theoretical -160
  /// because everything below it is room noise, and a waveform that reacts to
  /// room noise looks like a toy.
  void _onAmplitude(Amplitude a) {
    if (!mounted) return;
    final level = ((a.current + 45) / 45).clamp(0.0, 1.0);
    setState(() {
      _levels.add(level);
      if (_levels.length > 64) _levels.removeAt(0);
    });
  }

  Future<void> _stop() async {
    if (!_recording) return;
    final path = _path;
    final started = _startedAt;
    _tick?.cancel();
    await _amplitude?.cancel();
    _amplitude = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // Already stopped.
    }
    if (mounted) {
      setState(() {
        _recording = false;
        _elapsed = Duration.zero;
        _levels.clear();
        _path = null;
        _startedAt = null;
      });
    }
    if (path == null || started == null) return;

    // A clip too short to be deliberate is a mis-tap, and leaving it in the
    // list is how a recorder collects junk.
    final file = File(path);
    if (!file.existsSync() ||
        DateTime.now().difference(started) < const Duration(milliseconds: 700)) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    await _load();
  }

  // ── Playback ───────────────────────────────────────────────────────────────

  Future<void> _togglePlay(_Clip clip) async {
    if (_playing == clip.path) {
      await _player.pause();
      if (mounted) setState(() => _playing = null);
      return;
    }
    try {
      await _player.setFilePath(clip.path);
      await _player.play();
      if (mounted) setState(() => _playing = clip.path);
    } catch (_) {
      if (mounted) setState(() => _playing = null);
    }
  }

  /// The door — see the class doc for why this state and not another.
  void _onReadoutHold() {
    if (!_recording && _elapsed == Duration.zero) runEntryGate();
  }

  // ── Rendering ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = coverTheme(
      primary: const Color(0xFFE64A19),
      surface: const Color(0xFF17161A),
      brightness: Brightness.dark,
    );
    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(title: const Text('Recorder')),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 8),
              // The door. Passive: no ink, no handler, nothing to press.
              GestureDetector(
                onLongPress: _onReadoutHold,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 12,),
                  child: Text(
                    _clock(_elapsed),
                    style: TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w200,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 72,
                width: double.infinity,
                child: CustomPaint(
                  painter: _WavePainter(
                    levels: _levels,
                    color: theme.colorScheme.primary,
                    idle: theme.colorScheme.outlineVariant,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _RecordButton(recording: _recording, onTap: _toggleRecording),
              const SizedBox(height: 16),
              const Divider(),
              Expanded(
                child: !_loaded
                    ? const SizedBox.shrink()
                    : _clips.isEmpty
                        ? Center(
                            child: Text(
                              'No recordings',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _clips.length,
                            separatorBuilder: (_, __) => const Divider(),
                            itemBuilder: (context, i) {
                              final c = _clips[i];
                              return Dismissible(
                                key: ValueKey(c.path),
                                direction: DismissDirection.endToStart,
                                background: ColoredBox(
                                  color: theme.colorScheme.surfaceContainerHigh,
                                  child: const Align(
                                    alignment: Alignment.centerRight,
                                    child: Padding(
                                      padding: EdgeInsets.only(right: 20),
                                      child: Icon(Icons.delete_outline),
                                    ),
                                  ),
                                ),
                                onDismissed: (_) => _delete(c),
                                child: ListTile(
                                  leading: Icon(
                                    _playing == c.path
                                        ? Icons.pause_circle_outline
                                        : Icons.play_circle_outline,
                                  ),
                                  title: Text(c.title),
                                  subtitle: Text(c.subtitle),
                                  onTap: () => _togglePlay(c),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _clock(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({required this.recording, required this.onTap});

  final bool recording;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: recording ? 'Stop recording' : 'Record',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outline, width: 3),
          ),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: recording ? 30 : 56,
              height: recording ? 30 : 56,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(recording ? 6 : 28),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.levels,
    required this.color,
    required this.idle,
  });

  final List<double> levels;
  final Color color;
  final Color idle;

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 64;
    final w = size.width / bars;
    final mid = size.height / 2;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars; i++) {
      // Newest on the right, so the trace scrolls the way a level meter does.
      final index = i - (bars - levels.length);
      final level = index >= 0 && index < levels.length ? levels[index] : 0.0;
      final h = 2 + level * (size.height - 8);
      paint
        ..color = level > 0 ? color : idle
        ..strokeWidth = w * 0.5;
      final x = w * i + w / 2;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}

/// One recording on disk. Everything shown about it is read from the file, so
/// there is no metadata store to keep in step and nothing to go stale.
class _Clip {
  const _Clip({
    required this.path,
    required this.recordedAt,
    required this.bytes,
  });

  static _Clip? fromFile(File f) {
    final name = f.uri.pathSegments.last;
    final match = RegExp(r'^rec_(\d+)\.m4a$').firstMatch(name);
    if (match == null) return null;
    try {
      return _Clip(
        path: f.path,
        recordedAt:
            DateTime.fromMillisecondsSinceEpoch(int.parse(match.group(1)!)),
        bytes: f.lengthSync(),
      );
    } on FileSystemException {
      return null;
    }
  }

  final String path;
  final DateTime recordedAt;
  final int bytes;

  String get title {
    final d = recordedAt;
    final stamp = '${d.year}${_two(d.month)}${_two(d.day)}_'
        '${_two(d.hour)}${_two(d.minute)}${_two(d.second)}';
    return 'Recording $stamp';
  }

  String get subtitle {
    final kb = bytes / 1024;
    final size = kb >= 1024
        ? '${(kb / 1024).toStringAsFixed(1)} MB'
        : '${kb.round()} KB';
    return '${_two(recordedAt.day)}/${_two(recordedAt.month)}/'
        '${recordedAt.year}  ·  $size';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
