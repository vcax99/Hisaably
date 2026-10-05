import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/widgets/wave_background.dart';

void main() {
  test('runs when wanted and not held; holds nest; stop wins', () {
    final clock = WaveClock();
    addTearDown(clock.dispose);
    expect(clock.running, isFalse);

    clock.start();
    expect(clock.running, isTrue);

    clock
      ..hold()
      ..hold();
    expect(clock.running, isFalse, reason: 'scrolling');
    clock.release();
    expect(clock.running, isFalse, reason: 'one scroll still active');
    clock.release();
    expect(clock.running, isTrue);

    clock
      ..release() // an extra release is harmless
      ..hold()
      ..stop() // app backgrounded while scrolling
      ..release();
    expect(clock.running, isFalse, reason: 'stopped stays stopped');
    clock.start();
    expect(clock.running, isTrue);
  });
}
