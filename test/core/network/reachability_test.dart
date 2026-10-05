import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/network/network_status.dart';
import 'package:hisaably/core/network/reachability.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final network = NetworkStatus.instance;
  tearDown(() => network.debugSet(true));

  Reachability with_(MockClientHandler handler) => Reachability(
    client: MockClient(handler),
    network: network,
    timeout: const Duration(milliseconds: 100),
  );

  test('our auth server answering → reachable', () async {
    final r = with_(
      (req) async => http.Response('{"version":"v2","name":"GoTrue"}', 200),
    );
    expect(await r.check(), isTrue);
  });

  test('captive portal page (HTML 200) → unreachable', () async {
    final r = with_(
      (_) async => http.Response('<html>Login to Wi-Fi</html>', 200),
    );
    expect(await r.check(), isFalse);
  });

  test('server error / other JSON → unreachable', () async {
    expect(
      await with_((_) async => http.Response('oops', 503)).check(),
      isFalse,
    );
    expect(
      await with_((_) async => http.Response('{"name":"nginx"}', 200)).check(),
      isFalse,
    );
  });

  test('hanging request times out → unreachable', () async {
    final r = with_((_) => Completer<http.Response>().future);
    expect(await r.check(), isFalse);
  });

  test('no network: no request at all', () async {
    var calls = 0;
    network.debugSet(false);
    final r = with_((_) async {
      calls++;
      return http.Response('{"name":"GoTrue"}', 200);
    });
    expect(await r.check(), isFalse);
    expect(calls, 0);
  });
}
