import 'dart:async';

import 'package:flutter/foundation.dart';

import '../network/network_status.dart';
import 'outbox_processor.dart';

/// Why a sync was attempted (spec §22 triggers; no polling).
enum SyncTrigger {
  /// App start / sign-in.
  startup,

  /// App returned to the foreground.
  resume,

  /// The OS reports a network again.
  networkRegained,

  /// "Sync now" / "Retry".
  manual,

  /// An item's backoff delay elapsed while the app is open.
  scheduled,
}

/// Decides WHEN to drain the outbox. The [OutboxProcessor] decides HOW.
///
/// - Only syncs when the backend is reachable (real check, not just
///   "has Wi-Fi"); after the network returns it re-checks a few times,
///   because DHCP/captive portals take a moment.
/// - While the app is in the foreground and the server is reachable but
///   failing, a single timer fires when the next item's backoff ends.
///   Offline/unreachable there is no timer at all: the next trigger (network
///   change, resume, "Sync now") tries again. No polling.
class SyncEngine {
  /// [_isReachable] is normally `Reachability().check`.
  SyncEngine(
    this._outbox,
    this._isReachable, {
    NetworkStatus? network,
    DateTime Function()? clock,
    this.regainDelays = const [
      Duration.zero,
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15),
    ],
  }) : _network = network ?? NetworkStatus.instance,
       _clock = clock ?? DateTime.now;

  final OutboxProcessor _outbox;
  final Future<bool> Function() _isReachable;
  final NetworkStatus _network;
  final DateTime Function() _clock;

  /// Re-check schedule after the network comes back.
  final List<Duration> regainDelays;

  Timer? _timer;
  bool _foreground = true;
  bool _disposed = false;

  @visibleForTesting
  bool get hasScheduledTimer => _timer?.isActive ?? false;

  Future<FlushResult> sync(SyncTrigger trigger) async {
    if (_disposed) return const FlushResult();
    if (!_network.hasNetwork) return const FlushResult(offline: true);
    final reachable = trigger == SyncTrigger.networkRegained
        ? await _reachableWithRetries()
        : await _isReachable();
    if (!reachable) {
      // No timer while unreachable (that would be polling): the next
      // network change, resume or "Sync now" tries again.
      _cancelTimer();
      return const FlushResult(offline: true);
    }
    final result = await _outbox.flush(
      // Backoff exists for a failing server; any trigger other than the
      // timer means "conditions changed, try everything now".
      force: trigger != SyncTrigger.scheduled,
    );
    if (result.offline) {
      _cancelTimer(); // lost the connection mid-flush: wait for a trigger
    } else {
      await reschedule();
    }
    return result;
  }

  Future<bool> _reachableWithRetries() async {
    for (final delay in regainDelays) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (_disposed || !_network.hasNetwork) return false;
      if (await _isReachable()) return true;
    }
    return false;
  }

  /// One timer for the earliest due item, only while in the foreground.
  /// Also called after a write's immediate send attempt.
  Future<void> reschedule() async {
    _cancelTimer();
    if (!_foreground || _disposed) return;
    final due = await _outbox.nextDueAt();
    if (due == null || !_foreground || _disposed) return;
    var wait = due.difference(_clock().toUtc());
    if (wait < const Duration(seconds: 1)) wait = const Duration(seconds: 1);
    _timer = Timer(wait, () => unawaited(sync(SyncTrigger.scheduled)));
  }

  /// App went to the background: no timers (background work is the OS's
  /// call, see background_sync.dart).
  void paused() {
    _foreground = false;
    _cancelTimer();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<FlushResult> resumed() {
    _foreground = true;
    return sync(SyncTrigger.resume);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
