import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Continuous decorative motion (background waves, the logo's idle float).
/// Always on in the app; widget/device test harnesses switch it off because
/// `pumpAndSettle` can never settle while something animates forever.
bool ambientMotionEnabled = true;

/// Shared time source for the background waves, so every page's backdrop is
/// in phase (no jump when navigating). Ticks ~20×/s — the waves are slow, so
/// this looks smooth at a third of the work of 60 fps — and only while the
/// app is in the foreground and the system allows motion.
class WaveClock extends ChangeNotifier {
  Timer? _timer;
  final _watch = Stopwatch();

  /// Seconds of wave time.
  double get seconds => _watch.elapsedMicroseconds / 1e6;

  bool get running => _timer != null;

  bool _wanted = false;
  int _holds = 0;

  /// While something scrolls, the waves hold still: scrolling then costs
  /// exactly what it would without the background animation.
  void hold() {
    _holds++;
    _apply();
  }

  void release() {
    if (_holds > 0) _holds--;
    _apply();
  }

  void start() {
    _wanted = true;
    _apply();
  }

  void stop() {
    _wanted = false;
    _apply();
  }

  void _apply() {
    if (_wanted && _holds == 0) {
      _run();
    } else {
      _halt();
    }
  }

  void _run() {
    if (_timer != null) return;
    _watch.start();
    _timer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => notifyListeners(),
    );
  }

  void _halt() {
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  @override
  void dispose() {
    _halt();
    super.dispose();
  }
}

/// Owns the [WaveClock] (put it above the Navigator, e.g. in
/// MaterialApp.builder).
class WaveClockScope extends StatefulWidget {
  const WaveClockScope({super.key, required this.child});

  final Widget child;

  static WaveClock? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_WaveClockInherited>()?.clock;

  @override
  State<WaveClockScope> createState() => _WaveClockScopeState();
}

class _WaveClockScopeState extends State<WaveClockScope> {
  final _clock = WaveClock();
  late final AppLifecycleListener _lifecycle;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: _sync,
      onShow: _sync,
      onHide: _clock.stop,
      onPause: _clock.stop,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  void _sync() {
    if (_reduceMotion || !ambientMotionEnabled) {
      _clock.stop();
    } else {
      _clock.start();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _WaveClockInherited(clock: _clock, child: widget.child);
}

class _WaveClockInherited extends InheritedWidget {
  const _WaveClockInherited({required this.clock, required super.child});

  final WaveClock clock;

  @override
  bool updateShouldNotify(_WaveClockInherited old) => old.clock != clock;
}

/// A page's background: the app's near-black with slow green waves at the
/// bottom and a faint glow at the top. Opaque, so page transitions never
/// show the previous page through the new one.
class WaveBackdrop extends StatefulWidget {
  const WaveBackdrop({super.key, required this.child});

  final Widget child;

  @override
  State<WaveBackdrop> createState() => _WaveBackdropState();
}

class _WaveBackdropState extends State<WaveBackdrop> {
  WaveClock? _clock;

  /// Scrolls in progress on this page (released if the page goes away
  /// mid-scroll, so the waves never stay frozen).
  int _holds = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final clock = WaveClockScope.maybeOf(context);
    if (clock != _clock) {
      _releaseAll();
      _clock = clock;
    }
  }

  void _releaseAll() {
    for (; _holds > 0; _holds--) {
      _clock?.release();
    }
  }

  @override
  void dispose() {
    _releaseAll();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollStartNotification) {
      _holds++;
      _clock?.hold();
    } else if (n is ScrollEndNotification && _holds > 0) {
      _holds--;
      _clock?.release();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: CustomPaint(painter: WavePainter(_clock))),
            widget.child,
          ],
        ),
      );
}

class WavePainter extends CustomPainter {
  WavePainter(this.clock) : super(repaint: clock);

  /// Null → a still frame (tests, reduced motion before the clock exists).
  final WaveClock? clock;

  static const _layers = [
    // (height share, amplitude, wavelength share, speed, phase, colour, alpha)
    (0.30, 18.0, 1.10, 0.16, 0.0, AppColors.accent, 0.060),
    (0.24, 14.0, 0.80, -0.22, 1.7, AppColors.income, 0.045),
    (0.17, 10.0, 0.62, 0.30, 3.1, AppColors.accent, 0.050),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = AppColors.background);

    // Faint glow, top right.
    canvas.drawCircle(
      Offset(size.width * 0.9, -size.height * 0.02),
      size.width * 0.7,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                AppColors.accent.withValues(alpha: 0.07),
                AppColors.accent.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width * 0.9, -size.height * 0.02),
                radius: size.width * 0.7,
              ),
            ),
    );

    final t = clock?.seconds ?? 0;
    for (final (share, amp, wave, speed, phase, color, alpha) in _layers) {
      final baseY = size.height * (1 - share);
      final lambda = size.width * wave;
      final shift = t * speed * 2 * math.pi + phase;
      final path = Path()..moveTo(0, size.height);
      for (var x = 0.0; x <= size.width + 8; x += 8) {
        final y =
            baseY +
            amp * math.sin(2 * math.pi * x / lambda + shift) +
            amp *
                0.35 *
                math.sin(2 * math.pi * x / (lambda * 0.47) - shift * 1.3);
        path.lineTo(x, y);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader =
              LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: alpha),
                  color.withValues(alpha: alpha * 0.25),
                ],
              ).createShader(
                Rect.fromLTRB(0, baseY - amp, size.width, size.height),
              ),
      );
    }
  }

  @override
  bool shouldRepaint(WavePainter old) => old.clock != clock;
}
