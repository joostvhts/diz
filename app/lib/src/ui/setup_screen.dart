import 'package:flutter/material.dart';

import '../api/bridge_client.dart';
import '../settings.dart';

/// Creates an API client for a bridge address and (optional) access token.
typedef ApiFactory = LightsApi Function(Uri url, String? token);

/// Asks for the bridge address and access token, and checks that they work.
/// Shown on first run and when changing the bridge in Settings.
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.apiFactory,
    required this.onConnected,
    this.initialUrl,
    this.initialToken,
    this.autoConnect = false,
  });

  final ApiFactory apiFactory;
  final void Function(Uri url, String? token) onConnected;
  final Uri? initialUrl;
  final String? initialToken;

  /// Try [initialUrl] right away (used on the web, where the bridge usually
  /// serves the app itself).
  final bool autoConnect;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _address =
      TextEditingController(text: _display(widget.initialUrl) ?? defaultBridgeUrlText);
  late final TextEditingController _token = TextEditingController(text: widget.initialToken ?? '');
  bool _busy = false;
  bool _showToken = false;
  String? _addressError;
  String? _tokenError;

  static String? _display(Uri? url) {
    if (url == null) return null;
    final text = url.toString();
    return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect && widget.initialUrl != null) _connect(quiet: true);
  }

  @override
  void dispose() {
    _address.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect({bool quiet = false}) async {
    final url = parseBridgeUrl(_address.text);
    if (url == null) {
      setState(() => _addressError = 'Enter an address like lights.example.com');
      return;
    }
    final token = _token.text.trim().isEmpty ? null : _token.text.trim();
    setState(() {
      _busy = true;
      _addressError = null;
      _tokenError = null;
    });
    final api = widget.apiFactory(url, token);
    try {
      final health = await api.health();
      if (health.name != 'diz-bridge') {
        throw const BridgeException('That address answered, but it is not a Diz bridge.');
      }
      widget.onConnected(url, token);
    } on BridgeException catch (e) {
      if (mounted && !quiet) {
        setState(() {
          if (e.isUnauthorized) {
            _tokenError = token == null
                ? 'This bridge requires an access token.'
                : 'The bridge rejected this token.';
          } else {
            _addressError = e.message;
          }
        });
      }
    } finally {
      api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.lightbulb, size: 56, color: theme.colorScheme.primary),
                    const SizedBox(height: 16),
                    Text('Welcome to Diz', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(
                      'Diz controls your WiZ lights through a Diz bridge on your home network. '
                      'Enter its address and, if it has one, its access token.',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _address,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Bridge address',
                        hintText: 'lights.example.com',
                        helperText: 'https:// is used unless you type http://',
                        errorText: _addressError,
                        errorMaxLines: 4,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _token,
                      enabled: !_busy,
                      obscureText: !_showToken,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => _connect(),
                      decoration: InputDecoration(
                        labelText: 'Access token',
                        helperText: 'DIZ_API_TOKEN from the bridge configuration',
                        errorText: _tokenError,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _showToken ? 'Hide token' : 'Show token',
                          icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                          onPressed: () => setState(() => _showToken = !_showToken),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _connect,
                      child: _busy
                          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Connect'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
