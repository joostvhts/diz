import 'dart:convert';

import 'package:diz/src/api/bridge_client.dart';
import 'package:diz_core/diz_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final base = Uri.parse('https://lights.example.com/');
  final healthJson = jsonEncode(
      const BridgeHealth(name: 'diz-bridge', version: '0.2.0', apiVersion: dizApiVersion, lightCount: 0)
          .toJson());

  test('sends the bearer token on every request', () async {
    final seen = <String?>[];
    final client = MockClient((request) async {
      seen.add(request.headers['authorization']);
      return http.Response(request.url.path == '/api/health' ? healthJson : '{"lights":[]}', 200);
    });
    final api = HttpBridgeClient(base, token: ' my-token-0123456789 ', client: client);
    await api.health();
    await api.lights();
    expect(seen, ['Bearer my-token-0123456789', 'Bearer my-token-0123456789']);
  });

  test('sends no authorization header without a token', () async {
    String? header = 'unset';
    final client = MockClient((request) async {
      header = request.headers['authorization'];
      return http.Response(healthJson, 200);
    });
    await HttpBridgeClient(base, token: '', client: client).health();
    expect(header, isNull);
  });

  test('a 401 becomes an unauthorized BridgeException', () async {
    final client = MockClient((_) async => http.Response('{"error":"Missing or wrong access token"}', 401));
    await expectLater(
      HttpBridgeClient(base, token: 'wrong-token-0123456789', client: client).lights(),
      throwsA(isA<BridgeException>()
          .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)
          .having((e) => e.message, 'message', contains('rejected the access token'))),
    );
  });

  test('requests go to paths below the base URL', () async {
    Uri? url;
    final client = MockClient((request) async {
      url = request.url;
      return http.Response(healthJson, 200);
    });
    await HttpBridgeClient(Uri.parse('https://example.com/diz/'), client: client).health();
    expect(url.toString(), 'https://example.com/diz/api/health');
  });
}
