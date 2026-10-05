import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'wave_background.dart' show ambientMotionEnabled;

/// Currency drawn on the coin.
enum LogoSymbol { rupee, dollar }

/// The Hisaably mark: an "H" of two pillars (the group's two sides, income
/// and expense) bridged by a coin with a currency sign. Drawn in code so the
/// in-app logo, the animations and the exported launcher icons
/// (test/tool/export_branding_test.dart) are always identical.
class HisaablyLogoPainter extends CustomPainter {
  const HisaablyLogoPainter({
    this.progress = 1,
    this.tile = true,
    this.bob = 0,
    this.coinTilt = 0,
    this.symbol = LogoSymbol.rupee,
  });

  /// 0 → nothing drawn, 1 → complete (the build-in animation).
  final double progress;

  /// Draw the dark rounded tile behind the mark.
  final bool tile;

  /// Idle float, in design units (−1…1 → ±2.5 of 100).
  final double bob;

  /// Idle coin wiggle, in radians.
  final double coinTilt;

  final LogoSymbol symbol;

  static double _phase(double t, double start, double end) =>
      ((t - start) / (end - start)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 100; // design grid: 100 × 100
    canvas
      ..save()
      ..translate((size.width - 100 * s) / 2, (size.height - 100 * s) / 2)
      ..scale(s);

    if (tile) {
      final rect = RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 100, 100),
        const Radius.circular(24),
      );
      canvas
        ..drawRRect(
          rect,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.elevated, AppColors.background],
            ).createShader(const Rect.fromLTWH(0, 0, 100, 100)),
        )
        ..drawRRect(
          rect.deflate(0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = AppColors.border,
        );
    }

    canvas.translate(0, -2.5 * bob);
    final accent = Paint()..color = AppColors.accent;
    const pillarTop = 22.0;
    const pillarBottom = 78.0;
    const pillarWidth = 14.0;

    // Pillars rise from the bottom, left then right.
    for (final (x, start) in [(15.0, 0.0), (71.0, 0.12)]) {
      final t = Curves.easeOutCubic.transform(
        _phase(progress, start, start + 0.45),
      );
      if (t <= 0) continue;
      final top = pillarBottom - (pillarBottom - pillarTop) * t;
      canvas.drawRRect(
        RRect.fromLTRBR(
          x,
          top,
          x + pillarWidth,
          pillarBottom,
          const Radius.circular(7),
        ),
        accent,
      );
    }

    // Bar sweeps from the left pillar to the right one.
    final bar = Curves.easeInOutCubic.transform(_phase(progress, 0.45, 0.7));
    if (bar > 0) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          24,
          45.5,
          24 + 52 * bar,
          54.5,
          const Radius.circular(4.5),
        ),
        accent,
      );
    }

    // Coin pops in on the bar, then wiggles now and then.
    final coin = Curves.elasticOut.transform(_phase(progress, 0.62, 1));
    if (coin > 0) {
      const c = Offset(50, 50);
      final r = 16.0 * coin;
      canvas
        ..save()
        ..translate(c.dx, c.dy)
        ..rotate(coinTilt)
        ..translate(-c.dx, -c.dy)
        ..drawCircle(c, r + 2 * coin, Paint()..color = AppColors.background)
        ..drawCircle(c, r, accent)
        ..drawCircle(
          c,
          math.max(0, r - 2.6 * coin),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2 * coin
            ..color = AppColors.background.withValues(alpha: 0.55),
        );
      if (coin > 0.4) _drawSymbol(canvas, c, coin);
      canvas.restore();
    }
    canvas.restore();
  }

  void _drawSymbol(Canvas canvas, Offset c, double scale) {
    final ink = Paint()
      ..color = AppColors.background
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas
      ..save()
      ..translate(c.dx, c.dy)
      ..scale(scale.clamp(0.0, 1.0));
    switch (symbol) {
      case LogoSymbol.rupee:
        // ₹: two bars, a bowl, and the diagonal leg.
        final path = Path()
          ..moveTo(-5.5, -8)
          ..lineTo(5.5, -8)
          ..moveTo(-5.5, -3.5)
          ..lineTo(5.5, -3.5)
          ..moveTo(-5.5, -8)
          ..lineTo(-1.5, -8)
          ..cubicTo(4.5, -8, 4.5, 1, -1.5, 1)
          ..lineTo(-5.5, 1)
          ..lineTo(4.5, 9.5);
        canvas.drawPath(path, ink);
      case LogoSymbol.dollar:
        final path = Path()
          ..moveTo(5, -5.5)
          ..cubicTo(3.5, -8, -5.5, -8.5, -5.5, -3.5)
          ..cubicTo(-5.5, 1, 5.5, -1, 5.5, 3.5)
          ..cubicTo(5.5, 8.5, -3.5, 8, -5, 5.5)
          ..moveTo(0, -10.5)
          ..lineTo(0, 10.5);
        canvas.drawPath(path, ink);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(HisaablyLogoPainter old) =>
      old.progress != progress ||
      old.tile != tile ||
      old.bob != bob ||
      old.coinTilt != coinTilt ||
      old.symbol != symbol;
}

/// The logo, alive: builds itself in once ([buildIn]), then keeps a gentle
/// float and gives the coin a little wiggle every few seconds. Still when the
/// system asks to reduce motion.
class HisaablyLogo extends StatefulWidget {
  const HisaablyLogo({
    super.key,
    this.size = 40,
    this.tile = true,
    this.buildIn = false,
  });

  final double size;
  final bool tile;

  /// Play the pillars-bar-coin build animation first (splash, sign-in).
  final bool buildIn;

  @override
  State<HisaablyLogo> createState() => _HisaablyLogoState();
}

class _HisaablyLogoState extends State<HisaablyLogo>
    with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
    value: widget.buildIn ? 0 : 1,
  );

  /// One idle cycle: float up and down once; the coin wiggles at the start.
  late final AnimationController _idle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _intro.value = 1;
      _idle.stop();
      return;
    }
    if (_intro.value < 1) {
      _intro.forward().whenComplete(_startIdle);
    } else {
      _startIdle();
    }
  }

  void _startIdle() {
    if (mounted &&
        !_reduceMotion &&
        ambientMotionEnabled &&
        !_idle.isAnimating) {
      _idle.repeat();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_intro, _idle]),
        builder: (_, _) {
          final t = _idle.value;
          // Damped wiggle in the first 25% of each cycle.
          final w = t < 0.25
              ? math.sin(t / 0.25 * math.pi * 3) * (1 - t / 0.25)
              : 0.0;
          return CustomPaint(
            painter: HisaablyLogoPainter(
              progress: _intro.value,
              tile: widget.tile,
              bob: math.sin(t * 2 * math.pi),
              coinTilt: w * 0.22,
            ),
          );
        },
      ),
    ),
  );
}
