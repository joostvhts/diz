import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api/bridge_client.dart';
import 'settings.dart';
import 'state/lights_controller.dart';
import 'ui/home_screen.dart';
import 'ui/setup_screen.dart';

class DizApp extends StatefulWidget {
  const DizApp({super.key, required this.settings, this.apiFactory});

  final AppSettings settings;

  /// Creates the API client for a bridge; replaceable in tests.
  final ApiFactory? apiFactory;

  @override
  State<DizApp> createState() => _DizAppState();
}

class _DizAppState extends State<DizApp> {
  LightsController? _controller;
  Uri? _url;
  String? _token;

  LightsApi _api(Uri url, String? token) =>
      (widget.apiFactory ?? (url, token) => HttpBridgeClient(url, token: token))(url, token);

  @override
  void initState() {
    super.initState();
    _url = widget.settings.bridgeUrl;
    _token = widget.settings.apiToken;
    if (_url != null) _controller = _newController(_url!, _token);
  }

  LightsController _newController(Uri url, String? token) =>
      LightsController(api: _api(url, token))..start();

  Future<void> _onConnected(Uri url, String? token) async {
    await widget.settings.setConnection(url, token);
    _url = url;
    _token = token;
    _replaceController(() => _newController(url, token));
  }

  void _changeBridge() => _replaceController(() => null);

  void _replaceController(LightsController? Function() create) {
    final old = _controller;
    setState(() => _controller = create());
    // Dispose after the frame so widgets listening to it are gone first.
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// On the web the bridge usually serves the app, so its own origin is the best guess.
  Uri? get _webOrigin => kIsWeb ? Uri.base.replace(path: '/', query: null, fragment: null) : null;

  ThemeData _theme(Brightness brightness) => ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFFA000), brightness: brightness),
        useMaterial3: true,
      );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return MaterialApp(
      title: 'Diz',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: controller == null
          ? SetupScreen(
              apiFactory: _api,
              initialUrl: _url ?? _webOrigin,
              initialToken: _token,
              autoConnect: _url == null && kIsWeb,
              onConnected: _onConnected,
            )
          : HomeScreen(controller: controller, onChangeBridge: _changeBridge),
    );
  }
}
