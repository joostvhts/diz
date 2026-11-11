import 'dart:async';
import 'dart:convert';

import 'package:diz_core/diz_core.dart';
import 'package:http/http.dart' as http;

/// Something went wrong talking to the bridge. [message] is shown to the user.
class BridgeException implements Exception {
  const BridgeException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

/// The bridge API as the app uses it. An interface so tests can fake it.
abstract interface class LightsApi {
  Uri get baseUrl;
  Future<BridgeHealth> health();
  Future<List<Light>> lights();
  Future<Light> setLight(String id, SetStateCommand command);
  Future<GroupResult> setGroup(SetStateCommand command, {List<String>? ids});
  Future<Light> rename(String id, String name);
  Future<({int added, List<Light> lights})> discover();
  void close();
}

/// [LightsApi] over HTTP. Uses only `package:http`, so it works on Android and on the web.
class HttpBridgeClient implements LightsApi {
  HttpBridgeClient(
    this.baseUrl, {
    String? token,
    http.Client? client,
    this.timeout = const Duration(seconds: 6),
  })  : _token = (token == null || token.trim().isEmpty) ? null : token.trim(),
        _client = client ?? http.Client();

  @override
  final Uri baseUrl;
  final Duration timeout;

  /// Sent as `Authorization: Bearer <token>` when the bridge requires one.
  final String? _token;
  final http.Client _client;

  @override
  Future<BridgeHealth> health() async => BridgeHealth.fromJson(await _call('GET', 'api/health'));

  @override
  Future<List<Light>> lights() async => lightsFromJson((await _call('GET', 'api/lights'))['lights']);

  @override
  Future<Light> setLight(String id, SetStateCommand command) async => _light(await _call(
      'POST', 'api/lights/${Uri.encodeComponent(id)}/state',
      body: command.toJson()));

  @override
  Future<GroupResult> setGroup(SetStateCommand command, {List<String>? ids}) async =>
      GroupResult.fromJson(
          await _call('POST', 'api/group/state', body: {...command.toJson(), 'ids': ?ids}));

  @override
  Future<Light> rename(String id, String name) async => _light(
      await _call('PATCH', 'api/lights/${Uri.encodeComponent(id)}', body: {'name': name}));

  @override
  Future<({int added, List<Light> lights})> discover() async {
    final json = await _call('POST', 'api/discover',
        body: const <String, Object?>{}, timeout: const Duration(seconds: 20));
    return (added: (json['added'] as num?)?.toInt() ?? 0, lights: lightsFromJson(json['lights']));
  }

  @override
  void close() => _client.close();

  Light _light(Map<String, Object?> json) =>
      Light.fromJson((json['light'] as Map).cast<String, Object?>());

  Future<Map<String, Object?>> _call(String method, String path,
      {Object? body, Duration? timeout}) async {
    final request = http.Request(method, baseUrl.resolve(path));
    final token = _token;
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
          await _client.send(request).timeout(timeout ?? this.timeout));
    } on TimeoutException {
      throw BridgeException('The bridge at ${baseUrl.host} did not respond in time.');
    } on http.ClientException catch (e) {
      if (e.message.toLowerCase().contains('cleartext')) {
        throw const BridgeException(
            'Plain http:// addresses are blocked. Use the https:// address of your bridge.');
      }
      throw BridgeException('Cannot reach the bridge at ${baseUrl.host}: ${e.message}');
    } catch (e) {
      throw BridgeException('Cannot reach the bridge at ${baseUrl.host}: $e');
    }

    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode == 401) {
      throw BridgeException(
        _token == null
            ? 'This bridge requires an access token. Add it in Settings → Change.'
            : 'The bridge rejected the access token. Check it in Settings → Change.',
        statusCode: 401,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = decoded is Map ? decoded['error'] : null;
      throw BridgeException(
        error is String ? error : 'The bridge answered with HTTP ${response.statusCode}.',
        statusCode: response.statusCode,
      );
    }
    if (decoded is! Map) {
      throw const BridgeException('The bridge sent an unexpected response. Is this a Diz bridge?');
    }
    return decoded.cast<String, Object?>();
  }
}
