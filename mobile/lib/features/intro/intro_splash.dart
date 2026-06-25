import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:miles/core/services/app_lock.dart';

/// A romantic, light pink-and-white intro. Two illustrated sweethearts glide in
/// from each side — the groom from the left, the bride in a long red dress from
/// the right — meet in the middle, hug, then kiss, blooming a soft pink
/// heart-cloud that reads "For the love of my life". Lingers until the biometric
/// unlock is done (with a readable minimum), then fades. Tap to skip.
class IntroSplash extends StatefulWidget {
  const IntroSplash({super.key});

  @override
  State<IntroSplash> createState() => _IntroSplashState();
}

class _IntroSplashState extends State<IntroSplash>
    with TickerProviderStateMixin {
  late final AnimationController _scene = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 5200),
  )..forward();

  double _opacity = 1;
  bool _gone = false;
  bool _minPassed = false;
  Timer? _minTimer;
  Timer? _maxTimer;

  @override
  void initState() {
    super.initState();
    _minTimer = Timer(const Duration(milliseconds: 7000), () {
      _minPassed = true;
      _maybeDismiss();
    });
    _maxTimer = Timer(const Duration(milliseconds: 14000), _dismiss);
    AppLock.locked.addListener(_maybeDismiss);
  }

  void _maybeDismiss() {
    if (!_minPassed) return;
    if (!AppLock.locked.value) _dismiss();
  }

  void _dismiss() {
    if (_gone || !mounted) return;
    setState(() => _opacity = 0);
    Timer(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _gone = true);
    });
  }

  @override
  void dispose() {
    _minTimer?.cancel();
    _maxTimer?.cancel();
    AppLock.locked.removeListener(_maybeDismiss);
    _scene.dispose();
    super.dispose();
  }

  double _seg(double v, double a, double b) =>
      ((v - a) / (b - a)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    return Positioned.fill(
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 850),
        curve: Curves.easeOut,
        child: GestureDetector(
          onTap: () {
            _minPassed = true;
            _dismiss();
          },
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFFFFFFF),
                  Color(0xFFFFEAF1),
                  Color(0xFFFAD0DF)
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
            child: AnimatedBuilder(
              animation: _scene,
              builder: (context, _) {
                final v = _scene.value;

                // ── phases ──
                final slide = Curves.easeOutCubic.transform(_seg(v, 0.0, 0.42));
                final hug = Curves.easeInOut.transform(_seg(v, 0.42, 0.60));
                final kiss = Curves.easeInOut.transform(_seg(v, 0.60, 0.80));
                final cloud = Curves.elasticOut.transform(_seg(v, 0.78, 1.0));
                final cloudFade = _seg(v, 0.78, 0.9);
                final credit = _seg(v, 0.7, 1.0);

                var xGroom = lerpDouble(-2.0, -0.30, slide)!;
                var xBride = lerpDouble(2.0, 0.30, slide)!;
                xGroom = lerpDouble(xGroom, -0.20, hug)!;
                xBride = lerpDouble(xBride, 0.20, hug)!;
                xGroom = lerpDouble(xGroom, -0.15, kiss)!;
                xBride = lerpDouble(xBride, 0.15, kiss)!;
                final lean = lerpDouble(0.0, 0.16, kiss)!;
                final bob = math.sin((hug + kiss) * math.pi) * 0.012;

                return Stack(
                  children: [
                    ..._clouds(),
                    // groom (left)
                    Align(
                      alignment: Alignment(xGroom, 0.30 + bob),
                      child: Transform.rotate(
                        angle: lean,
                        alignment: Alignment.bottomCenter,
                        child: const SizedBox(
                          width: 120,
                          height: 210,
                          child: CustomPaint(painter: _GroomPainter()),
                        ),
                      ),
                    ),
                    // bride (right)
                    Align(
                      alignment: Alignment(xBride, 0.30 + bob),
                      child: Transform.rotate(
                        angle: -lean,
                        alignment: Alignment.bottomCenter,
                        child: const SizedBox(
                          width: 120,
                          height: 210,
                          child: CustomPaint(painter: _BridePainter()),
                        ),
                      ),
                    ),
                    // pink heart-cloud with the line, blooming on the kiss
                    if (cloudFade > 0)
                      Align(
                        alignment: const Alignment(0, -0.42),
                        child: Opacity(
                          opacity: cloudFade,
                          child: Transform.scale(
                            scale: (0.4 + cloud * 0.6).clamp(0.0, 1.0),
                            child: _heartCloud(),
                          ),
                        ),
                      ),
                    // credit
                    Align(
                      alignment: const Alignment(0, 0.86),
                      child: Opacity(
                        opacity: credit,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                                width: 34,
                                height: 1,
                                color: const Color(0x55B23A5A)),
                            const SizedBox(height: 12),
                            Text(
                              'DEVELOPED BY HER HUSBAND',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 2.8,
                                color: const Color(0xFF9A4A63),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _heartCloud() {
    return SizedBox(
      width: 250,
      height: 215,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
              size: const Size(250, 215), painter: _HeartCloudPainter()),
          Padding(
            padding: const EdgeInsets.only(top: 24, left: 36, right: 36),
            child: Text(
              'For the love\nof my life',
              textAlign: TextAlign.center,
              style: GoogleFonts.fraunces(
                fontSize: 21,
                fontWeight: FontWeight.w500,
                height: 1.25,
                color: Colors.white,
                shadows: const [
                  Shadow(color: Color(0x55B01F45), blurRadius: 6),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // A few soft drifting cloud puffs for the dreamy backdrop.
  List<Widget> _clouds() {
    Widget puff(double a, double b, double scale, double op) => Align(
          alignment: Alignment(a, b),
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 120,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: op),
                borderRadius: BorderRadius.circular(40),
              ),
            ),
          ),
        );
    return [
      puff(-0.7, -0.78, 1.0, 0.7),
      puff(0.75, -0.62, 1.3, 0.55),
      puff(-0.55, 0.55, 1.1, 0.4),
      puff(0.6, 0.66, 0.9, 0.35),
    ];
  }
}

// ───────────────────────────── illustrations ─────────────────────────────

const _skinM = Color(0xFFE9B492);
const _skinF = Color(0xFFF1C3A6);
const _hairDark = Color(0xFF2C211B);
const _hairF = Color(0xFF3A2722);
const _suit = Color(0xFF33323F);
const _suitDark = Color(0xFF24232E);
const _dressRed = Color(0xFFD62B45);
const _dressDeep = Color(0xFFB01F38);

void _face(Canvas c, Offset head, double r) {
  final eye = Paint()..color = const Color(0xFF2A2320);
  c.drawCircle(head.translate(-r * 0.34, -r * 0.05), r * 0.11, eye);
  c.drawCircle(head.translate(r * 0.34, -r * 0.05), r * 0.11, eye);
  // cheeks
  final blush = Paint()..color = const Color(0x33E0566B);
  c.drawCircle(head.translate(-r * 0.55, r * 0.28), r * 0.16, blush);
  c.drawCircle(head.translate(r * 0.55, r * 0.28), r * 0.16, blush);
  // smile
  final smile = Paint()
    ..color = const Color(0xFF8E3A46)
    ..style = PaintingStyle.stroke
    ..strokeWidth = r * 0.09
    ..strokeCap = StrokeCap.round;
  c.drawArc(
      Rect.fromCircle(center: head.translate(0, r * 0.18), radius: r * 0.34),
      0.5,
      2.14,
      false,
      smile);
}

class _GroomPainter extends CustomPainter {
  const _GroomPainter();
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final skin = Paint()..color = _skinM;

    // legs + shoes
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.40, h * 0.72, w * 0.09, h * 0.24),
            Radius.circular(w * 0.045)),
        Paint()..color = _suitDark);
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.51, h * 0.72, w * 0.09, h * 0.24),
            Radius.circular(w * 0.045)),
        Paint()..color = _suitDark);
    c.drawOval(Rect.fromLTWH(w * 0.36, h * 0.94, w * 0.17, h * 0.045),
        Paint()..color = const Color(0xFF161420));
    c.drawOval(Rect.fromLTWH(w * 0.48, h * 0.94, w * 0.17, h * 0.045),
        Paint()..color = const Color(0xFF161420));

    // jacket
    final torso = Path()
      ..moveTo(w * 0.28, h * 0.44)
      ..lineTo(w * 0.72, h * 0.44)
      ..lineTo(w * 0.66, h * 0.76)
      ..lineTo(w * 0.34, h * 0.76)
      ..close();
    c.drawPath(torso, Paint()..color = _suit);
    // shirt V
    c.drawPath(
        Path()
          ..moveTo(w * 0.5, h * 0.44)
          ..lineTo(w * 0.43, h * 0.44)
          ..lineTo(w * 0.5, h * 0.64)
          ..lineTo(w * 0.57, h * 0.44)
          ..close(),
        Paint()..color = Colors.white);
    // bow tie
    final tie = Paint()..color = _dressDeep;
    c.drawPath(
        Path()
          ..moveTo(w * 0.5, h * 0.455)
          ..lineTo(w * 0.43, h * 0.43)
          ..lineTo(w * 0.43, h * 0.48)
          ..close(),
        tie);
    c.drawPath(
        Path()
          ..moveTo(w * 0.5, h * 0.455)
          ..lineTo(w * 0.57, h * 0.43)
          ..lineTo(w * 0.57, h * 0.48)
          ..close(),
        tie);

    // arms (sleeves) — inner arm reaches toward partner (the hug)
    final sleeve = Paint()
      ..color = _suit
      ..strokeWidth = w * 0.11
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    c.drawLine(Offset(w * 0.31, h * 0.48), Offset(w * 0.24, h * 0.64), sleeve);
    c.drawLine(Offset(w * 0.69, h * 0.48), Offset(w * 0.86, h * 0.58), sleeve);
    c.drawCircle(Offset(w * 0.24, h * 0.64), w * 0.055, skin);
    c.drawCircle(Offset(w * 0.86, h * 0.58), w * 0.055, skin);

    // neck + head
    c.drawRect(Rect.fromLTWH(w * 0.45, h * 0.38, w * 0.10, h * 0.07), skin);
    final head = Offset(w * 0.5, h * 0.27);
    final r = w * 0.18;
    c.drawCircle(head, r, skin);
    // hair cap
    c.save();
    c.clipPath(Path()..addOval(Rect.fromCircle(center: head, radius: r)));
    c.drawRect(Rect.fromLTWH(head.dx - r, head.dy - r, r * 2, r * 0.95),
        Paint()..color = _hairDark);
    c.restore();
    _face(c, head, r);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BridePainter extends CustomPainter {
  const _BridePainter();
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final skin = Paint()..color = _skinF;

    // long red gown — bell from waist to floor
    final gown = Path()
      ..moveTo(w * 0.40, h * 0.46)
      ..quadraticBezierTo(w * 0.06, h * 0.82, w * 0.14, h * 0.97)
      ..lineTo(w * 0.86, h * 0.97)
      ..quadraticBezierTo(w * 0.94, h * 0.82, w * 0.60, h * 0.46)
      ..close();
    c.drawPath(gown, Paint()..color = _dressRed);
    // soft sheen panel
    c.drawPath(
        Path()
          ..moveTo(w * 0.5, h * 0.50)
          ..quadraticBezierTo(w * 0.40, h * 0.78, w * 0.46, h * 0.96)
          ..lineTo(w * 0.56, h * 0.96)
          ..quadraticBezierTo(w * 0.58, h * 0.78, w * 0.5, h * 0.50)
          ..close(),
        Paint()..color = const Color(0x33FFFFFF));
    // fitted bodice
    c.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(w * 0.36, h * 0.36, w * 0.28, h * 0.12),
            Radius.circular(w * 0.05)),
        Paint()..color = _dressDeep);

    // arms — inner arm reaches toward partner
    final arm = Paint()
      ..color = _skinF
      ..strokeWidth = w * 0.075
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    c.drawLine(Offset(w * 0.34, h * 0.42), Offset(w * 0.22, h * 0.56), arm);
    c.drawLine(Offset(w * 0.66, h * 0.42), Offset(w * 0.16, h * 0.54), arm);

    // neck + head
    c.drawRect(Rect.fromLTWH(w * 0.45, h * 0.31, w * 0.10, h * 0.07), skin);
    final head = Offset(w * 0.5, h * 0.21);
    final r = w * 0.18;
    // hair behind (flowing)
    c.drawPath(
        Path()
          ..moveTo(head.dx - r * 1.05, head.dy)
          ..quadraticBezierTo(head.dx - r * 1.3, head.dy + r * 2.4,
              head.dx - r * 0.4, head.dy + r * 2.6)
          ..lineTo(head.dx + r * 0.4, head.dy + r * 2.6)
          ..quadraticBezierTo(
              head.dx + r * 1.3, head.dy + r * 2.4, head.dx + r * 1.05, head.dy)
          ..close(),
        Paint()..color = _hairF);
    c.drawCircle(head, r, skin);
    // hair top
    c.save();
    c.clipPath(Path()..addOval(Rect.fromCircle(center: head, radius: r)));
    c.drawRect(Rect.fromLTWH(head.dx - r, head.dy - r, r * 2, r * 0.85),
        Paint()..color = _hairF);
    c.restore();
    _face(c, head, r);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A soft, puffy pink heart "cloud".
class _HeartCloudPainter extends CustomPainter {
  const _HeartCloudPainter();
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.30)
      ..cubicTo(w * 0.5, h * 0.06, w * 0.07, h * 0.05, w * 0.07, h * 0.37)
      ..cubicTo(w * 0.07, h * 0.64, w * 0.42, h * 0.80, w * 0.5, h * 0.98)
      ..cubicTo(w * 0.58, h * 0.80, w * 0.93, h * 0.64, w * 0.93, h * 0.37)
      ..cubicTo(w * 0.93, h * 0.05, w * 0.5, h * 0.06, w * 0.5, h * 0.30)
      ..close();
    // glow
    c.drawPath(
        path,
        Paint()
          ..color = const Color(0x66FF8FB0)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18));
    // body
    c.drawPath(
        path,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFF9DBC), Color(0xFFF06A93)],
          ).createShader(Rect.fromLTWH(0, 0, w, h)));
    // soft highlight
    c.drawCircle(Offset(w * 0.30, h * 0.30), w * 0.10,
        Paint()..color = const Color(0x44FFFFFF));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
