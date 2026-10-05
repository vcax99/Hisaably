import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/env.dart';
import 'network_status.dart';

/// Is the backend actually reachable (spec: "a real reachability check, not
/// just connectivity")? Connected-but-no-internet and captive portals (which
/// answer with their own HTML page) both count as unreachable.
class Reachability {
  Reachability({
    http.Client? client,
    NetworkStatus? network,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client ?? http.Client(),
       _network = network ?? NetworkStatus.instance;

  final http.Client _client;
  final NetworkStatus _network;
  final Duration timeout;

  Future<bool> check() async {
    if (!_network.hasNetwork) return false;
    try {
      final res = await _client
          .get(
            Uri.parse('${Env.supabaseUrl}/auth/v1/health'),
            headers: {'apikey': Env.supabasePublishableKey},
          )
          .timeout(timeout);
      if (res.statusCode != 200) return false;
      final body = jsonDecode(res.body);
      // Our auth server's signature, not some portal's page.
      return body is Map && body['name'] == 'GoTrue';
    } catch (_) {
      return false;
    }
  }
}
