import 'package:diz_core/diz_core.dart';
import 'package:flutter/material.dart';

import '../api/bridge_client.dart';
import '../state/lights_controller.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller, required this.onChangeBridge});

  final LightsController controller;
  final VoidCallback onChangeBridge;

  void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _discover(BuildContext context) async {
    try {
      final added = await controller.discover();
      if (context.mounted) {
        _snack(context, added == 0 ? 'No new lights found' : 'Found $added new light${added == 1 ? '' : 's'}');
      }
    } on BridgeException catch (e) {
      if (context.mounted) _snack(context, e.message);
    }
  }

  Future<void> _rename(BuildContext context, Light light) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameDialog(initial: light.name),
    );
    if (name == null || name.trim().isEmpty || name.trim() == light.name) return;
    try {
      await controller.rename(light.id, name);
    } on BridgeException catch (e) {
      if (context.mounted) _snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final health = controller.health;
          return ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.router_outlined),
                title: const Text('Bridge'),
                subtitle: Text([
                  controller.api.baseUrl.toString(),
                  if (health != null) 'version ${health.version}',
                  if (controller.error != null) 'not reachable',
                ].join(' · ')),
                trailing: TextButton(onPressed: onChangeBridge, child: const Text('Change')),
              ),
              ListTile(
                leading: const Icon(Icons.search),
                title: const Text('Search for new lights'),
                subtitle: const Text('The bridge also does this every few minutes'),
                onTap: () => _discover(context),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text('Lights', style: theme.textTheme.titleSmall),
              ),
              for (final light in controller.lights)
                ListTile(
                  title: Text(light.name),
                  subtitle: Text([
                    light.online ? (light.ip ?? '') : 'offline',
                    ?light.model,
                    if (light.firmware != null) 'fw ${light.firmware}',
                    if (light.rssi != null) '${light.rssi} dBm',
                  ].where((s) => s.isNotEmpty).join(' · ')),
                  trailing: IconButton(
                    tooltip: 'Rename',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _rename(context, light),
                  ),
                ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('About Diz'),
                subtitle: Text(
                  'Local control for WiZ lights, without the cloud. '
                  'Diz is not affiliated with WiZ or Signify.',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename light'),
      content: TextField(
        controller: _text,
        autofocus: true,
        maxLength: 64,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_text.text), child: const Text('Save')),
      ],
    );
  }
}
