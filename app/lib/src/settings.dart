import 'package:diz_core/diz_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bridge address to suggest on first run, set at build time:
/// `flutter build apk --dart-define=DIZ_BRIDGE_URL=https://lights.example.com`.
/// Never put the access token here; it is entered in the app.
const String defaultBridgeUrlText = String.fromEnvironment('DIZ_BRIDGE_URL');

/// Persistent app settings: the bridge address and its access token.
///
/// Stored in the app's private preferences, which other apps can't read.
class AppSettings {
  AppSettings._(this._prefs);

  static const _bridgeUrlKey = 'bridgeUrl';
  static const _tokenKey = 'bridgeToken';

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async => AppSettings._(await SharedPreferences.getInstance());

  Uri? get bridgeUrl {
    final text = _prefs.getString(_bridgeUrlKey);
    return text == null ? null : parseBridgeUrl(text);
  }

  /// Bearer token for the bridge, or null if it doesn't require one.
  String? get apiToken => _prefs.getString(_tokenKey);

  Future<void> setConnection(Uri url, String? token) async {
    await _prefs.setString(_bridgeUrlKey, url.toString());
    if (token == null || token.isEmpty) {
      await _prefs.remove(_tokenKey);
    } else {
      await _prefs.setString(_tokenKey, token);
    }
  }
}

/// Turns user input into a base URL ending in `/`:
/// * `lights.example.com` → `https://lights.example.com/` (HTTPS is the default);
/// * `http://192.168.1.5` → `http://192.168.1.5:8787/` (a bridge without a proxy in
///   front; release builds on Android refuse plain HTTP, debug builds allow it).
Uri? parseBridgeUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final port = uri.hasPort ? uri.port : (uri.scheme == 'http' ? defaultBridgePort : null);
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  return Uri(scheme: uri.scheme, host: uri.host, port: port, path: path);
}
