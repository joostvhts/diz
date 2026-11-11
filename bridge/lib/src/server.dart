import 'dart:convert';

import 'package:diz_core/diz_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'registry.dart';
import 'version.dart';
import 'wiz/wiz_transport.dart';

/// Builds the HTTP handler:
/// * `/healthz` - unauthenticated liveness check for Docker / the reverse proxy;
/// * `/api/...` - the JSON API, behind a bearer token when [apiToken] is set;
/// * everything else - a static web UI ([webRoot]) or a short status text.
Handler buildHandler(
  Registry registry, {
  String? apiToken,
  String? webRoot,
  bool devCors = false,
  void Function(String message, bool isError)? logger,
}) {
  final expectedToken = apiToken == null ? null : utf8.encode(apiToken);
  final api = Router(notFoundHandler: (Request r) => _error(404, 'Unknown API route: ${r.method} /${r.url.path}'))
    ..get('/api/health', (Request request) {
      return _json(BridgeHealth(
        name: 'diz-bridge',
        version: bridgeVersion,
        apiVersion: dizApiVersion,
        lightCount: registry.count,
      ).toJson());
    })
    ..get('/api/lights', (Request request) async {
      final lights = await registry.refresh();
      return _json({'lights': [for (final l in lights) l.toJson()]});
    })
    ..post('/api/lights/<id>/state', (Request request, String id) async {
      final command = SetStateCommand.fromJson(await _body(request));
      final problem = command.validate();
      if (problem != null) return _error(400, problem);
      final light = await registry.setState(id, command);
      return _json({'light': light.toJson()});
    })
    ..patch('/api/lights/<id>', (Request request, String id) async {
      final body = await _body(request);
      final name = body['name'];
      if (name is! String) return _error(400, 'name must be a string');
      final light = await registry.rename(id, name);
      return _json({'light': light.toJson()});
    })
    ..post('/api/group/state', (Request request) async {
      final body = await _body(request);
      final ids = body['ids'];
      if (ids != null && (ids is! List || ids.any((i) => i is! String))) {
        return _error(400, 'ids must be a list of light ids');
      }
      final command = SetStateCommand.fromJson(body);
      final problem = command.validate();
      if (problem != null) return _error(400, problem);
      final result = await registry.setGroupState(command, ids: (ids as List?)?.cast<String>());
      return _json(result.toJson());
    })
    ..post('/api/discover', (Request request) async {
      final added = await registry.discover();
      await registry.refresh();
      return _json({'added': added, 'lights': [for (final l in registry.lights) l.toJson()]});
    });

  final Handler other = webRoot != null
      ? createStaticHandler(webRoot, defaultDocument: 'index.html')
      : (Request request) => Response.ok(
            'diz-bridge $bridgeVersion is running. The API is at /api (try /api/lights).\n',
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );

  Future<Response> root(Request request) async {
    final path = request.url.path;
    if (path == 'healthz') return _json({'status': 'ok'});
    if (path == 'api' || path.startsWith('api/')) {
      if (expectedToken != null && !_hasToken(request, expectedToken)) {
        return _json(
          {'error': 'Missing or wrong access token'},
          status: 401,
          extraHeaders: {'www-authenticate': 'Bearer realm="diz"'},
        );
      }
      try {
        return await api.call(request);
      } on UnknownLightException catch (e) {
        return _error(404, e.toString());
      } on WizTimeoutException catch (e) {
        return _error(504, 'Light did not respond: $e');
      } on WizException catch (e) {
        return _error(502, e.toString());
      } on FormatException catch (e) {
        return _error(400, e.message);
      }
    }
    return other(request);
  }

  var pipeline = const Pipeline().addMiddleware(logRequests(logger: logger));
  if (devCors) pipeline = pipeline.addMiddleware(_cors());
  return pipeline.addHandler(root);
}

Future<Map<String, Object?>> _body(Request request) async {
  final text = await request.readAsString();
  if (text.trim().isEmpty) return {};
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('Request body must be a JSON object');
  return decoded.cast<String, Object?>();
}

Response _json(Object body, {int status = 200, Map<String, String>? extraHeaders}) => Response(
      status,
      body: jsonEncode(body),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        ...?extraHeaders,
      },
    );

final _bearer = RegExp(r'^Bearer\s+(\S+)\s*$', caseSensitive: false);

bool _hasToken(Request request, List<int> expected) {
  final header = request.headers['authorization'];
  if (header == null) return false;
  final match = _bearer.firstMatch(header.trim());
  if (match == null) return false;
  return _constantTimeEquals(utf8.encode(match.group(1)!), expected);
}

/// Compares without an early exit, so response timing doesn't reveal how
/// much of a guessed token was right.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Response _error(int status, String message) => _json({'error': message}, status: status);

/// Permissive CORS for development (`flutter run -d web-server` on another port).
Middleware _cors() {
  const headers = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, PATCH, OPTIONS',
    'access-control-allow-headers': 'content-type, authorization',
  };
  return (inner) => (request) async {
        if (request.method == 'OPTIONS') return Response.ok(null, headers: headers);
        final response = await inner(request);
        return response.change(headers: headers);
      };
}
