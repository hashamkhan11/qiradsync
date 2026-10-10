import 'package:flutter_test/flutter_test.dart';

/// Waits for [condition] to become true, pumping a frame after a short real
/// delay each time, up to [timeout]. Call only from inside `tester.runAsync`.
///
/// A plain `tester.pump()` processes one frame and returns; it does not wait
/// for unrelated real I/O (sqflite's FFI calls) to finish, since that I/O
/// runs on its own, outside the frame schedule. A real `Future.delayed` gives
/// that I/O a slice of real time to progress before the next pump checks
/// again, so this is how a test can wait for "the write has landed" rather
/// than for "the next frame", without guessing a fixed number of pumps.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration step = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      await tester.pump();
      return; // Give up silently; the caller's own expect() reports this.
    }
    await Future<void>.delayed(step);
    await tester.pump();
  }
}
