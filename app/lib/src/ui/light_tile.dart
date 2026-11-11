import 'package:diz_core/diz_core.dart';
import 'package:flutter/material.dart';

import '../state/lights_controller.dart';
import 'colors.dart';
import 'control_panel.dart' show brightnessGradient;
import 'widgets/gradient_slider.dart';

/// One light in the list: color dot, name, state, on/off switch and a
/// brightness slider. Tap for the full controls.
class LightTile extends StatelessWidget {
  const LightTile({
    super.key,
    required this.light,
    required this.onTap,
    required this.onToggle,
    required this.onBrightness,
    this.selected = false,
  });

  final Light light;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onBrightness;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return _TileCard(
      selected: selected,
      onTap: onTap,
      leading: LightDot(color: displayColor(light), online: light.online),
      title: light.name,
      subtitle: describeState(light),
      switchValue: light.isOn,
      onToggle: light.online ? onToggle : null,
      brightness: light.online && light.capabilities.dimmable ? light.state?.brightness : null,
      onBrightness: onBrightness,
      switchLabel: 'Turn ${light.name} on or off',
    );
  }
}

/// "All lights" card at the top of the list.
class GroupTile extends StatelessWidget {
  const GroupTile({super.key, required this.controller, required this.onTap, this.selected = false});

  final LightsController controller;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final online = controller.onlineLights;
    final onCount = online.where((l) => l.isOn).length;
    final offline = controller.lights.length - online.length;
    final state = controller.groupState;
    final firstOn = online.where((l) => l.isOn).firstOrNull;
    return _TileCard(
      selected: selected,
      onTap: onTap,
      leading: LightDot(
        color: firstOn == null ? null : displayColor(firstOn),
        online: online.isNotEmpty,
        icon: Icons.lightbulb_circle_outlined,
      ),
      title: 'All lights',
      subtitle: [
        '$onCount of ${online.length} on',
        if (offline > 0) '$offline offline',
      ].join(' · '),
      switchValue: controller.anyOn,
      onToggle: online.isEmpty ? null : (on) => controller.setGroup(SetStateCommand(on: on)),
      brightness: online.isEmpty || !controller.groupCapabilities.dimmable ? null : state?.brightness,
      onBrightness: (v) => controller.setGroup(SetStateCommand(brightness: v)),
      switchLabel: 'Turn all lights on or off',
      emphasized: true,
    );
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.switchValue,
    required this.onToggle,
    required this.brightness,
    required this.onBrightness,
    required this.switchLabel,
    this.emphasized = false,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final String subtitle;
  final bool switchValue;
  final ValueChanged<bool>? onToggle;
  final int? brightness;
  final ValueChanged<int> onBrightness;
  final String switchLabel;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: selected
          ? scheme.secondaryContainer
          : (emphasized ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
          child: Column(
            children: [
              Row(
                children: [
                  leading,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: emphasized ? theme.textTheme.titleMedium : theme.textTheme.bodyLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Semantics(
                    label: switchLabel,
                    child: Switch(value: switchValue, onChanged: onToggle),
                  ),
                ],
              ),
              if (brightness != null)
                GradientSlider(
                  value: brightness!,
                  min: minBrightness,
                  max: maxBrightness,
                  colors: brightnessGradient,
                  label: (v) => '$v%',
                  semanticLabel: '$title brightness',
                  onChanged: onBrightness,
                )
              else
                const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round indicator showing the light's current color, or a dim bulb when off.
class LightDot extends StatelessWidget {
  const LightDot({super.key, required this.color, required this.online, this.icon});

  final Color? color;
  final bool online;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lit = color;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: lit ?? scheme.surfaceContainerHighest,
        boxShadow: lit == null ? null : [BoxShadow(color: lit.withValues(alpha: 0.55), blurRadius: 14)],
      ),
      child: Icon(
        !online ? Icons.power_off_outlined : (icon ?? (lit == null ? Icons.lightbulb_outline : Icons.lightbulb)),
        size: 22,
        color: lit == null
            ? scheme.onSurfaceVariant
            : (ThemeData.estimateBrightnessForColor(lit) == Brightness.dark ? Colors.white : Colors.black87),
      ),
    );
  }
}
