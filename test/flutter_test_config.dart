import 'dart:async';

import 'package:hisaably/core/widgets/wave_background.dart';

/// Runs before every test file: no endless decorative animations, so
/// `pumpAndSettle` can settle.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  ambientMotionEnabled = false;
  await testMain();
}
