import 'dart:async';

import 'package:diz_core/diz_core.dart';
import 'package:flutter/material.dart';

import '../api/bridge_client.dart';
import '../state/lights_controller.dart';
import 'control_panel.dart';
import 'light_tile.dart';
import 'settings_screen.dart';

/// Screens at least this wide show the controls in a side pane instead of a
/// bottom sheet (tablets, desktop browsers).
const double widePaneBreakpoint = 840;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller, required this.onChangeBridge});

  final LightsController controller;
  final VoidCallback onChangeBridge;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _selected;
  StreamSubscription<String>? _messages;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(_messages?.cancel());
      _listen();
    }
  }

  void _listen() {
    _messages = widget.controller.messages.listen(_showMessage);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    unawaited(_messages?.cancel());
    super.dispose();
  }

  void _open(String target, {required bool wide}) {
    if (wide) {
      setState(() => _selected = target);
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => SingleChildScrollView(
        child: ControlPanel(controller: widget.controller, target: target),
      ),
    );
  }

  Future<void> _discover() async {
    try {
      final added = await widget.controller.discover();
      _showMessage(added == 0 ? 'No new lights found' : 'Found $added new light${added == 1 ? '' : 's'}');
    } on BridgeException catch (e) {
      _showMessage(e.message);
    }
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => SettingsScreen(
        controller: widget.controller,
        onChangeBridge: () {
          Navigator.of(context).pop();
          widget.onChangeBridge();
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diz'),
        actions: [
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => IconButton(
              tooltip: 'Refresh',
              onPressed: controller.loading ? null : controller.refresh,
              icon: const Icon(Icons.refresh),
            ),
          ),
          IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.settings_outlined)),
        ],
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= widePaneBreakpoint;
        final list = ListenableBuilder(
          listenable: controller,
          builder: (context, _) => _buildList(context, wide: wide),
        );
        if (!wide) return list;
        final selected = _selected;
        return Row(
          children: [
            SizedBox(width: 420, child: list),
            const VerticalDivider(width: 1),
            Expanded(
              child: selected == null
                  ? const Center(child: Text('Select a light'))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 16),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: ControlPanel(
                            key: ValueKey(selected),
                            controller: controller,
                            target: selected,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildList(BuildContext context, {required bool wide}) {
    final c = widget.controller;
    final health = c.health;
    return RefreshIndicator(
      onRefresh: c.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        children: [
          if (c.error != null)
            _Notice(
              icon: Icons.wifi_off,
              message: c.error!,
              action: TextButton(onPressed: c.refresh, child: const Text('Retry')),
              isError: true,
            ),
          if (health != null && !health.isCompatible)
            _Notice(
              icon: Icons.update,
              message: 'This bridge (${health.version}) speaks API version ${health.apiVersion}, '
                  'but this app expects version $dizApiVersion. Update the '
                  '${health.apiVersion < dizApiVersion ? 'bridge' : 'app'}.',
            ),
          if (!c.loaded && c.error == null)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (c.loaded && c.lights.isEmpty)
            _EmptyState(onDiscover: _discover),
          if (c.lights.isNotEmpty) ...[
            GroupTile(
              controller: c,
              selected: wide && _selected == groupKey,
              onTap: () => _open(groupKey, wide: wide),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
              child: Text('Lights', style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final light in c.lights)
              LightTile(
                key: ValueKey(light.id),
                light: light,
                selected: wide && _selected == light.id,
                onTap: () => _open(light.id, wide: wide),
                onToggle: (on) => c.setLight(light.id, SetStateCommand(on: on)),
                onBrightness: (v) => c.setLight(light.id, SetStateCommand(brightness: v)),
              ),
          ],
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message, this.action, this.isError = false});

  final IconData icon;
  final String message;
  final Widget? action;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = isError ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Card(
      elevation: 0,
      color: isError ? scheme.errorContainer : scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(icon, color: fg),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: TextStyle(color: fg))),
            ?action,
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onDiscover});

  final VoidCallback onDiscover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(Icons.lightbulb_outline, size: 56, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('No lights yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'The bridge finds WiZ lights on its network automatically. Make sure they are '
            'powered and that "Allow local communication" is enabled in the WiZ app.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onDiscover,
            icon: const Icon(Icons.search),
            label: const Text('Search for lights'),
          ),
        ],
      ),
    );
  }
}
