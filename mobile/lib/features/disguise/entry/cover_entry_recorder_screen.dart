import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miles/core/services/app_lock.dart';
import 'package:miles/core/ui/theme.dart';
import 'package:miles/core/widgets/glow_button.dart';
import 'package:miles/core/widgets/stealth_overlay.dart';
import 'package:miles/features/disguise/disguise_cover_host.dart';
import 'package:miles/features/disguise/disguise_profile.dart';
import 'package:miles/features/disguise/entry/cover_entry_scope.dart';
import 'package:miles/features/disguise/entry/cover_entry_trigger.dart';
import 'package:miles/features/disguise/entry/entry_trigger_layer.dart';

enum _Step { choose, record, confirm, done }

enum _Kind { touch, text }

/// Records the owner's way in, on the cover it will open.
///
/// The real cover is drawn here, under the same theme and in the same box the
/// host draws it in, with the same pointer layer over it in record mode — so
/// what is recorded is exactly what will be matched.
///
/// Two performances, not three. The second is not ceremony: it is where the
/// tolerances come from — centre, radius and hold length are all derived from
/// the owner's own variance between the two — and a move they cannot repeat
/// is refused there rather than stored. A third pass was tried on a handset
/// and cut; it proved nothing the second had not already proved, and three
/// goes at an unfamiliar gesture is where people give up.
///
/// While the move is being made, every tap and hold is drawn as a numbered
/// mark, and on the second pass the first attempt sits underneath as a faint
/// guide. Nothing is ever drawn on the cover itself: silence there is what
/// stops a miss telling a stranger they were close.
///
/// Inside the authenticated app, so the stealth corner and the panic
/// detector are switched off for its lifetime: a hold recorded in the
/// top-right corner would otherwise raise the "Syncing news" scrim over it,
/// and a vigorous rhythm could trip the shake detector.
class CoverEntryRecorderScreen extends StatefulWidget {
  const CoverEntryRecorderScreen({
    required this.cover,
    this.nowMs = wallClockMs,
    super.key,
  });

  final DisguiseCover cover;

  /// See [EntryTriggerLayer.nowMs].
  final int Function() nowMs;

  @override
  State<CoverEntryRecorderScreen> createState() =>
      _CoverEntryRecorderScreenState();
}

class _CoverEntryRecorderScreenState extends State<CoverEntryRecorderScreen>
    with WidgetsBindingObserver {
  _Step _step = _Step.choose;
  _Kind _kind = _Kind.touch;
  final List<TouchEvent> _attempt = [];
  List<TouchEvent>? _firstTouch;
  String? _firstText;
  CoverEntryTrigger? _derived;
  String? _error;
  bool _appLockOn = true;

  /// Built once. `build` runs on every recorded tap and hold, and
  /// `ColorScheme.fromSeed` is not free on the one screen whose smoothness
  /// the owner is judging.
  late final ThemeData _coverTheme = coverHostTheme();

  /// The card explains the step, and it also covers the top of the cover —
  /// which is a place the owner may want to put their move. Collapsing it
  /// leaves a one-line bar, so nowhere on the screen is out of reach while
  /// recording.
  bool _cardOpen = true;
  Size _box = Size.zero;
  Offset _origin = Offset.zero;

  /// The text sink is set only while a word is being recorded: with it set,
  /// every commit is consumed, and a touch-kind recording would be made on
  /// a calculator whose `=` never computes — not the widget the move is
  /// matched on later.
  late final CoverEntryController _c = CoverEntryController(
    mode: EntryLayerMode.record,
    onOpen: (_) {},
  )..onRecordedTouch = _onTouch;

  TextSlot? get _slot => TextSlot.forCover(widget.cover);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    stealthSuppressed.value = true;
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
    AppLock.isEnabled().then((on) {
      if (mounted) setState(() => _appLockOn = on);
    });
  }

  @override
  void dispose() {
    stealthSuppressed.value = false;
    // Put rotation back. Pinning portrait for the recorder and never
    // releasing it left the whole app portrait-locked for the rest of the
    // process — video calls and photos included.
    unawaited(
      SystemChrome.setPreferredOrientations(DeviceOrientation.values),
    );
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` is a notification banner or an incoming call sliding over
    // the screen — not the owner doing something wrong, and not something to
    // blame them for. Only a real backgrounding drops the attempt, which is
    // the case where the cover would have risen underneath it in the field.
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    if (_step == _Step.record || _step == _Step.confirm) {
      setState(() {
        _attempt.clear();
        _error = 'Interrupted — that attempt was cleared. Try again.';
      });
    }
  }

  void _onTouch(TouchEvent e) => setState(() {
        _attempt.add(e);
        _error = null;
      });

  void _onText(String raw) {
    // Only ever bound while a word is being recorded, and only on a cover
    // that has a slot — see _pick.
    final slot = _slot!;
    switch (_step) {
      case _Step.record:
        final err = TextTrigger.admissibilityError(raw, slot);
        if (err != null) {
          setState(() => _error = err);
          return;
        }
        setState(() {
          _firstText = raw;
          _error = null;
          _step = _Step.confirm;
        });
      case _Step.confirm:
        final (t, err) =
            TextTrigger.derive(_firstText!, raw, slot: slot, box: _box);
        if (t == null) {
          setState(() => _error = err);
          return;
        }
        _finishWith(t);
      case _Step.choose:
      case _Step.done:
        return;
    }
  }

  void _doneTouch() {
    final rec = List<TouchEvent>.of(_attempt);
    switch (_step) {
      case _Step.record:
        final err = TouchTrigger.admissibilityError(rec);
        if (err != null) {
          setState(() {
            _error = err;
            _attempt.clear();
          });
          return;
        }
        setState(() {
          _firstTouch = rec;
          _attempt.clear();
          _error = null;
          _step = _Step.confirm;
        });
      case _Step.confirm:
        final (t, err) = TouchTrigger.derive(
          _firstTouch!,
          rec,
          cover: widget.cover,
          box: _box,
        );
        if (t == null) {
          setState(() {
            _error = err;
            _attempt.clear();
          });
          return;
        }
        _finishWith(t);
      case _Step.choose:
      case _Step.done:
        return;
    }
  }

  void _finishWith(CoverEntryTrigger t) {
    FocusManager.instance.primaryFocus?.unfocus();
    // The one haptic in the whole feature: the cover itself never answers.
    HapticFeedback.mediumImpact();
    setState(() {
      _derived = t;
      _error = null;
      _step = _Step.done;
      _c.onRecordedText = null;
    });
  }

  void _pick(_Kind kind) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _kind = kind;
      _step = _Step.record;
      _error = null;
      // The cover was live under the card while the owner read it; nothing
      // touched then is a step of the move.
      _attempt.clear();
      _c.onRecordedText = kind == _Kind.text ? _onText : null;
    });
  }

  void _startOver() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _attempt.clear();
      _firstTouch = null;
      _firstText = null;
      _derived = null;
      _error = null;
      _step = _Step.record;
      _c.onRecordedText = _kind == _Kind.text ? _onText : null;
    });
  }

  /// Back out one step: from an attempt to the choice of kind, and only from
  /// there out of the recorder. Cancelling the whole flow from the middle of
  /// a recording was the only way to change your mind about the kind.
  void _back() {
    if (_step == _Step.record || _step == _Step.confirm) {
      setState(() {
        _attempt.clear();
        _firstTouch = null;
        _firstText = null;
        _error = null;
        _step = _Step.choose;
        _cardOpen = true;
        _c.onRecordedText = null;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  void _cancel() => Navigator.of(context).pop();

  void _finish() => Navigator.of(context).pop(_derived);

  String get _tally {
    if (_attempt.isEmpty) return 'Nothing yet';
    final taps = _attempt.where((e) => e.isTap).length;
    final holds = _attempt.length - taps;
    final t = taps == 1 ? '1 tap' : '$taps taps';
    final h = holds == 1 ? '1 hold' : '$holds holds';
    if (holds == 0) return t;
    if (taps == 0) return h;
    return '$t, $h';
  }

  /// The length is in the hint, not only in the refusal: being told the rule
  /// after breaking it is how a first attempt gets abandoned.
  String get _textHint => switch (_slot) {
        TextSlot.calc =>
          'At least six digits. Type it on the keypad, then press =.',
        TextSlot.convert => 'At least six digits. Type it as the amount, then '
            'tap the swap arrows.',
        TextSlot.notes => 'At least six characters. Make it the title of a '
            'new note, then tap Save.',
        null => '',
      };

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    _origin = Offset(media.padding.left, media.padding.top);
    _box = Size(
      media.size.width - media.padding.horizontal,
      media.size.height - media.padding.vertical,
    );
    final showMarks = _kind == _Kind.touch &&
        (_step == _Step.record || _step == _Step.confirm);
    // "That's it" reads as saved, and it is not until the move is handed
    // back. Android's back gesture pops with null, which every caller reads
    // as "cancelled" and silently drops — so back at that step hands the
    // move over instead of binning it.
    return PopScope(
      canPop: _step != _Step.done,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step == _Step.done) _finish();
      },
      child: Stack(
      children: [
        Theme(
          data: _coverTheme,
          child: CoverEntryScope(
            controller: _c,
            child: EntryTriggerLayer(
              controller: _c,
              nowMs: widget.nowMs,
              child: buildCoverWidget(widget.cover),
            ),
          ),
        ),
        // What the owner is setting, drawn where they set it. Above the
        // cover, below the card, and unable to take a touch.
        if (showMarks)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _MarkPainter(
                  marks: List<TouchEvent>.of(_attempt),
                  guide: _step == _Step.confirm ? _firstTouch : null,
                  origin: _origin,
                  box: _box,
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: _card(),
        ),
      ],
      ),
    );
  }

  Widget _card() {
    final recording = _step == _Step.record || _step == _Step.confirm;
    final title = switch (_step) {
      _Step.choose => "How you'll open Miles",
      _Step.record => _kind == _Kind.touch ? 'Do your move now.' : 'Type it now.',
      _Step.confirm => 'Once more, exactly the same.',
      _Step.done => "That's it — ${_derived!.summary}.",
    };
    final body = switch (_step) {
      _Step.choose => _chooseBody(),
      _Step.record || _Step.confirm => _attemptBody(title),
      _Step.done => _doneBody(),
    };
    return Material(
      key: const ValueKey('coverEntryCard'),
      color: MilesColors.surface1,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: recording && !_cardOpen ? _collapsedBar(title) : body,
        ),
      ),
    );
  }

  /// The card out of the way: enough to know which step this is and to finish
  /// or abandon it, and nothing covering the screen the move is made on.
  Widget _collapsedBar(String title) {
    return Row(
      children: [
        Expanded(
          child: Text(
            _error ?? '$title  ·  $_tally',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MilesType.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _error != null ? MilesColors.blush : MilesColors.cream50,
            ),
          ),
        ),
        if (_kind == _Kind.touch)
          TextButton(
            onPressed: _attempt.isEmpty ? null : _doneTouch,
            child: const Text('Done'),
          ),
        IconButton(
          onPressed: () => setState(() => _cardOpen = true),
          icon: const Icon(Icons.expand_more, color: MilesColors.gilt),
          tooltip: 'Show the instructions',
        ),
      ],
    );
  }

  Widget _title(String text) => Text(
        text,
        style: MilesType.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: MilesColors.cream50,
        ),
      );

  Widget _line(String text, {Color color = MilesColors.taupe}) => Text(
        text,
        style: MilesType.inter(fontSize: 12.5, height: 1.4, color: color),
      );

  Widget _chooseBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title("How you'll open Miles"),
        const SizedBox(height: 6),
        _line(
          'Record a move of your own on this screen. Nothing the app ships '
          'opens it — only what you record here. You do it twice.',
        ),
        const SizedBox(height: 12),
        _option(
          icon: Icons.touch_app_outlined,
          title: 'Taps and holds',
          subtitle: 'Tap or hold spots on this screen, in order. Each one is '
              'marked as you make it. Avoid buttons and keys — pick empty '
              'space or a readout.',
          onTap: () => _pick(_Kind.touch),
        ),
        if (_slot != null) ...[
          const SizedBox(height: 8),
          _option(
            icon: Icons.keyboard_outlined,
            title: _slot!.numeric ? 'A secret number' : 'A secret word',
            subtitle: _textHint,
            onTap: () => _pick(_Kind.text),
          ),
        ],
        if (!_appLockOn) ...[
          const SizedBox(height: 10),
          _line(
            'App Lock is off, so your move opens Miles directly. The backup '
            'hold always asks to unlock.',
          ),
        ],
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: _cancel, child: const Text('Cancel')),
        ),
      ],
    );
  }

  Widget _option({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: MilesColors.surface2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: MilesColors.gilt, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: MilesType.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: MilesColors.cream50,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _line(subtitle),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _attemptBody(String title) {
    final touch = _kind == _Kind.touch;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(title),
        const SizedBox(height: 6),
        if (_error != null)
          _line(_error!, color: MilesColors.blush)
        else if (touch)
          _line(
            _step == _Step.record
                ? 'A hold is about a second; a hold on its own needs three. '
                    'Taps alone need five quick ones, on two different spots.'
                : 'Same spots, same order, same rhythm. The faint marks are '
                    'where you put them the first time.',
          )
        else
          _line(_textHint),
        if (touch) ...[
          const SizedBox(height: 8),
          _line(_tally, color: MilesColors.gilt),
        ],
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 4,
          children: [
            TextButton(onPressed: _back, child: const Text('Back')),
            TextButton(
              onPressed: () => setState(() => _cardOpen = false),
              child: const Text('Hide this'),
            ),
            if (touch) ...[
              // On the second pass this returns to the FIRST one: a move the
              // owner cannot reproduce has to be abandonable, and a refusal
              // clears the attempt, which is exactly when a button gated on
              // "something recorded" would be dead.
              TextButton(
                onPressed: _step == _Step.confirm
                    ? _startOver
                    : (_attempt.isEmpty
                        ? null
                        : () => setState(_attempt.clear)),
                child: const Text('Start over'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: MilesColors.ember,
                ),
                onPressed: _attempt.isEmpty ? null : _doneTouch,
                child: const Text('Done'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _doneBody() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title("That's it — ${_derived!.summary}."),
        const SizedBox(height: 6),
        _line(
          'This move is the only way in from the cover. Practise it now, '
          'while you can still change it.',
        ),
        const SizedBox(height: 12),
        // Stacked, never a Row: at a large text scale two buttons side by
        // side overflow the card, and the one that gets clipped is the one
        // that finishes the flow.
        GlowButton(label: 'Use this move', onPressed: _finish),
        Align(
          alignment: Alignment.centerRight,
          child:
              TextButton(onPressed: _startOver, child: const Text('Start over')),
        ),
      ],
    );
  }
}

/// The move as the owner is making it: one numbered mark per step, a filled
/// dot for a tap and a ring for a hold, with the first attempt underneath as
/// a faint guide on the second pass.
class _MarkPainter extends CustomPainter {
  const _MarkPainter({
    required this.marks,
    required this.guide,
    required this.origin,
    required this.box,
  });

  final List<TouchEvent> marks;
  final List<TouchEvent>? guide;
  final Offset origin;
  final Size box;

  Offset _at(TouchEvent e) {
    final short = math.min(box.width, box.height);
    return origin + Offset(e.x * short, e.y * short);
  }

  void _draw(Canvas canvas, List<TouchEvent> events, {required bool faint}) {
    final colour = faint ? MilesColors.gilt : MilesColors.ember;
    final alpha = faint ? 0.35 : 0.9;
    final fill = Paint()..color = colour.withValues(alpha: alpha);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = faint ? 2 : 3
      ..color = colour.withValues(alpha: alpha);
    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      final c = _at(e);
      if (e.isTap) {
        canvas.drawCircle(c, 13, fill);
      } else {
        // A hold reads as a ring: bigger than a tap, and visibly a different
        // thing, because the two are different steps to reproduce.
        canvas
          ..drawCircle(c, 22, stroke)
          ..drawCircle(c, 7, fill);
      }
      if (faint) continue;
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, c - Offset(label.width / 2, label.height / 2));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final g = guide;
    if (g != null) _draw(canvas, g, faint: true);
    _draw(canvas, marks, faint: false);
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.marks.length != marks.length ||
      old.guide?.length != guide?.length ||
      old.origin != origin ||
      old.box != box;
}
