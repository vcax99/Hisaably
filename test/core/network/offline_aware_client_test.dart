import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hisaably/core/errors/app_failure.dart';
import 'package:hisaably/core/errors/error_mapper.dart';
import 'package:hisaably/core/network/network_status.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final status = NetworkStatus.instance;
  tearDown(() => status.debugSet(true));

  test('no network: fails instantly without touching the network', () async {
    var calls = 0;
    final client = OfflineAwareClient(
      inner: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
      status: status,
    );
    status.debugSet(false);
    final sw = Stopwatch()..start();
    final error = await client
        .get(Uri.parse('https://example.invalid/rest/v1/x'))
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 200)));
    expect(calls, 0);
    expect(error, isA<SocketException>());
    expect(mapError(error!), isA<NetworkFailure>());
  });

  test('with network: passes through', () async {
    final client = OfflineAwareClient(
      inner: MockClient((_) async => http.Response('ok', 200)),
      status: status,
    );
    final r = await client.get(Uri.parse('https://example.invalid/'));
    expect(r.body, 'ok');
  });

  test('a hanging request times out as a network failure', () async {
    final client = OfflineAwareClient(
      inner: MockClient((_) => Completer<http.Response>().future),
      status: status,
      timeout: const Duration(milliseconds: 50),
    );
    final error = await client
        .get(Uri.parse('https://example.invalid/'))
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isA<TimeoutException>());
    expect(mapError(error!), isA<NetworkFailure>());
  });
}
