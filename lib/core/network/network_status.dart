import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// What the OS reports about network interfaces (Wi-Fi, mobile, …).
///
/// "Has a network" doesn't guarantee the server is reachable; it only lets
/// us fail instantly when there is clearly no network, instead of waiting
/// for a DNS/connect timeout (~15s on Android in airplane mode).
class NetworkStatus {
  NetworkStatus._();

  static final instance = NetworkStatus._();

  bool _hasNetwork = true;
  final _changes = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  /// False only when the OS says there is no network at all.
  bool get hasNetwork => _hasNetwork;

  /// Emits the new value whenever [hasNetwork] changes.
  Stream<bool> get changes => _changes.stream;

  static bool _anyNetwork(List<ConnectivityResult> r) =>
      r.any((c) => c != ConnectivityResult.none);

  Future<void> start() async {
    final connectivity = Connectivity();
    try {
      _hasNetwork = _anyNetwork(await connectivity.checkConnectivity());
    } catch (e) {
      // Unknown: assume online and let requests decide.
      debugPrint('Connectivity check failed: ${e.runtimeType}');
    }
    _sub ??= connectivity.onConnectivityChanged.listen((r) {
      final next = _anyNetwork(r);
      if (next == _hasNetwork) return;
      _hasNetwork = next;
      _changes.add(next);
    });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Simulates losing/regaining the network (tests and device flows; the
  /// iOS simulator can't go offline on its own).
  @visibleForTesting
  void debugSet(bool hasNetwork) {
    if (hasNetwork == _hasNetwork) return;
    _hasNetwork = hasNetwork;
    _changes.add(hasNetwork);
  }
}

/// HTTP client for Supabase: fails immediately when there is no network and
/// gives up on requests that hang (connected to a network that doesn't
/// work). Both surface as a NetworkFailure, so the app falls back to its
/// local data right away.
class OfflineAwareClient extends http.BaseClient {
  OfflineAwareClient({
    http.Client? inner,
    NetworkStatus? status,
    this.timeout = const Duration(seconds: 12),
  }) : _inner = inner ?? http.Client(),
       _status = status ?? NetworkStatus.instance;

  final http.Client _inner;
  final NetworkStatus _status;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!_status.hasNetwork) {
      return Future.error(const SocketException('No network connection'));
    }
    return _inner.send(request).timeout(timeout);
  }

  @override
  void close() => _inner.close();
}
