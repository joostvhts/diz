import 'package:diz_core/diz_core.dart';
import 'package:flutter/material.dart';

Color colorOfRgb(Rgb rgb) => Color.fromARGB(255, rgb.r, rgb.g, rgb.b);

Rgb rgbOfColor(Color color) =>
    Rgb((color.r * 255).round(), (color.g * 255).round(), (color.b * 255).round());

Color colorOfKelvin(int kelvin) => colorOfRgb(kelvinToRgb(kelvin));

/// The color a light is showing, for dots and previews; null when it is off
/// or its look is unknown.
Color? displayColor(Light light) {
  final state = light.state;
  if (!light.online || state == null || !state.on) return null;
  return switch (state.mode) {
    ColorMode.rgb when state.rgb != null => colorOfRgb(state.rgb!),
    ColorMode.white when state.kelvin != null => colorOfKelvin(state.kelvin!),
    _ => colorOfKelvin(2700),
  };
}

/// Short description like "60% · 2700 K".
String describeState(Light light) {
  final state = light.state;
  if (!light.online) return 'Offline';
  if (state == null) return 'Unknown';
  if (!state.on) return 'Off';
  final parts = <String>[
    if (light.capabilities.dimmable) '${state.brightness}%',
    switch (state.mode) {
      ColorMode.white when state.kelvin != null => '${state.kelvin} K',
      ColorMode.rgb => 'Color',
      ColorMode.scene => 'Scene',
      _ => 'On',
    },
  ];
  return parts.join(' · ');
}
