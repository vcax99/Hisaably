// Exports the logo (lib/core/widgets/hisaably_logo.dart) as PNGs for the
// launcher icon and native splash generators. Only runs on request:
//   EXPORT_BRANDING=1 flutter test test/tool/export_branding_test.dart
// then: dart run flutter_launcher_icons && dart run flutter_native_splash:create
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/theme/app_colors.dart';
import 'package:hisaably/core/widgets/hisaably_logo.dart';

Future<void> _export(
  String path,
  double size, {
  required double markScale,
  bool background = false,
  bool tile = false,
  LogoSymbol symbol = LogoSymbol.rupee,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (background) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size, size),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.elevated, AppColors.background],
        ).createShader(Rect.fromLTWH(0, 0, size, size)),
    );
  }
  final mark = size * markScale;
  canvas
    ..save()
    ..translate((size - mark) / 2, (size - mark) / 2);
  HisaablyLogoPainter(
    tile: tile,
    symbol: symbol,
  ).paint(canvas, Size(mark, mark));
  canvas.restore();
  final image = await recorder.endRecording().toImage(
    size.toInt(),
    size.toInt(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  final enabled = Platform.environment['EXPORT_BRANDING'] == '1';

  testWidgets('export branding PNGs', (tester) async {
    await tester.runAsync(() async {
      // iOS + legacy Android: full-bleed square, no transparency.
      await _export(
        'assets/branding/icon.png',
        1024,
        markScale: 0.78,
        background: true,
      );
      // Android adaptive foreground: mark inside the 66% safe zone.
      await _export(
        'assets/branding/icon_foreground.png',
        1024,
        markScale: 0.78,
      );
      // Native splash: the tiled mark on the app background.
      await _export(
        'assets/branding/splash.png',
        768,
        markScale: 0.62,
        tile: true,
      );
      // Android 12+ splash icon (shown inside a circle).
      await _export(
        'assets/branding/splash_android12.png',
        1152,
        markScale: 0.7,
      );
      // Previews of both currency options (not used by the build).
      await _export(
        'build/branding/preview_rupee.png',
        512,
        markScale: 0.9,
        tile: true,
      );
      await _export(
        'build/branding/preview_dollar.png',
        512,
        markScale: 0.9,
        tile: true,
        symbol: LogoSymbol.dollar,
      );
    });
  }, skip: !enabled);
}
