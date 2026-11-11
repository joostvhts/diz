import 'package:diz_core/diz_core.dart';
import 'package:flutter/material.dart';

import '../state/lights_controller.dart';
import 'colors.dart';
import 'widgets/color_wheel.dart';
import 'widgets/gradient_slider.dart';

enum _Tab { white, color }

const brightnessGradient = [Color(0xFF3A3530), Color(0xFFFFF1D6)];

/// Full controls for one light, or for all lights when [target] is [groupKey]:
/// on/off, brightness, and white (Kelvin) or color.
///
/// Shown in a bottom sheet on phones and in a side pane on wide screens.
class ControlPanel extends StatefulWidget {
  const ControlPanel({super.key, required this.controller, required this.target});

  final LightsController controller;
  final String target;

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  _Tab? _tab;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final isGroup = widget.target == groupKey;
        final light = isGroup ? null : c.light(widget.target);
        if (!isGroup && light == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('This light is no longer known to the bridge.'),
          );
        }

        final caps = isGroup ? c.groupCapabilities : light!.capabilities;
        final state = isGroup ? c.groupState : light!.state;
        final enabled = isGroup ? c.onlineLights.isNotEmpty : light!.online;
        final title = isGroup ? 'All lights' : light!.name;
        void apply(SetStateCommand command) =>
            isGroup ? c.setGroup(command) : c.setLight(widget.target, command);

        final tabs = [if (caps.tunableWhite) _Tab.white, if (caps.color) _Tab.color];
        var tab = _tab ??
            (state?.mode == ColorMode.rgb && caps.color ? _Tab.color : null) ??
            (tabs.isEmpty ? null : tabs.first);
        if (!tabs.contains(tab)) tab = tabs.isEmpty ? null : tabs.first;

        final theme = Theme.of(context);
        final brightness = state?.brightness ?? maxBrightness;

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleLarge, overflow: TextOverflow.ellipsis),
                  ),
                  Switch(
                    value: enabled && (state?.on ?? false),
                    onChanged: enabled ? (on) => apply(SetStateCommand(on: on)) : null,
                  ),
                ],
              ),
              if (!enabled)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    isGroup
                        ? 'No lights are reachable right now.'
                        : 'This light is offline. Is it switched off at the wall?',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              if (state?.mode == ColorMode.scene && enabled)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Playing a WiZ scene. Pick a white or color to replace it.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (caps.dimmable) ...[
                const SizedBox(height: 16),
                _SectionLabel(icon: Icons.brightness_6_outlined, text: 'Brightness', value: '$brightness%'),
                GradientSlider(
                  value: brightness,
                  min: minBrightness,
                  max: maxBrightness,
                  colors: brightnessGradient,
                  label: (v) => '$v%',
                  semanticLabel: 'Brightness',
                  onChanged: enabled ? (v) => apply(SetStateCommand(brightness: v)) : null,
                ),
              ],
              if (tabs.length > 1) ...[
                const SizedBox(height: 12),
                SegmentedButton<_Tab>(
                  segments: const [
                    ButtonSegment(value: _Tab.white, label: Text('White'), icon: Icon(Icons.wb_sunny_outlined)),
                    ButtonSegment(value: _Tab.color, label: Text('Color'), icon: Icon(Icons.palette_outlined)),
                  ],
                  selected: {tab!},
                  onSelectionChanged: (selection) => setState(() => _tab = selection.first),
                ),
              ],
              const SizedBox(height: 16),
              if (tab == _Tab.white) _WhiteControls(caps: caps, state: state, enabled: enabled, apply: apply),
              if (tab == _Tab.color) _ColorControls(state: state, enabled: enabled, apply: apply),
            ],
          ),
        );
      },
    );
  }
}

class _WhiteControls extends StatelessWidget {
  const _WhiteControls({required this.caps, required this.state, required this.enabled, required this.apply});

  final Capabilities caps;
  final LightState? state;
  final bool enabled;
  final void Function(SetStateCommand) apply;

  static const _presets = [
    ('Candle', 2200),
    ('Warm', 2700),
    ('Neutral', 4000),
    ('Daylight', 5000),
    ('Cool', 6500),
  ];

  @override
  Widget build(BuildContext context) {
    final current = state?.mode == ColorMode.white ? state?.kelvin : null;
    final kelvin = caps.clampKelvin(current ?? 2700);
    final steps = 6;
    final gradient = [
      for (var i = 0; i <= steps; i++)
        colorOfKelvin(caps.kelvinMin + (caps.kelvinMax - caps.kelvinMin) * i ~/ steps),
    ];
    final presets = _presets.where((p) => p.$2 >= caps.kelvinMin && p.$2 <= caps.kelvinMax);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(
          icon: Icons.thermostat_outlined,
          text: 'Color temperature',
          value: current == null ? '' : '$current K',
        ),
        GradientSlider(
          value: kelvin,
          min: caps.kelvinMin,
          max: caps.kelvinMax,
          step: 50,
          colors: gradient,
          label: (v) => '$v K',
          semanticLabel: 'Color temperature',
          onChanged: enabled ? (v) => apply(SetStateCommand(kelvin: v)) : null,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (name, k) in presets)
              ChoiceChip(
                avatar: CircleAvatar(backgroundColor: colorOfKelvin(k), radius: 9),
                label: Text(name),
                selected: current == k,
                onSelected: enabled ? (_) => apply(SetStateCommand(kelvin: k)) : null,
              ),
          ],
        ),
      ],
    );
  }
}

class _ColorControls extends StatelessWidget {
  const _ColorControls({required this.state, required this.enabled, required this.apply});

  final LightState? state;
  final bool enabled;
  final void Function(SetStateCommand) apply;

  // Eight fit on one row on a phone.
  static const _swatches = [
    Rgb(255, 0, 0),
    Rgb(255, 90, 0),
    Rgb(255, 200, 0),
    Rgb(0, 255, 0),
    Rgb(0, 255, 190),
    Rgb(0, 0, 255),
    Rgb(140, 0, 255),
    Rgb(255, 0, 200),
  ];

  @override
  Widget build(BuildContext context) {
    final current = state?.mode == ColorMode.rgb ? state?.rgb : null;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColorWheel(
          color: current == null ? null : colorOfRgb(current),
          onChanged: enabled ? (color) => apply(SetStateCommand(rgb: rgbOfColor(color))) : null,
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final swatch in _swatches)
              Semantics(
                button: true,
                label: 'Color ${swatch.toHex()}',
                child: InkResponse(
                  onTap: enabled ? () => apply(SetStateCommand(rgb: swatch)) : null,
                  radius: 22,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: colorOfRgb(swatch).withValues(alpha: enabled ? 1 : 0.4),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: swatch == current ? theme.colorScheme.onSurface : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.text, required this.value});

  final IconData icon;
  final String text;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.labelLarge)),
          Text(value, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
