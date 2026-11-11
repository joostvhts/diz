import 'dart:math' as math;

import 'light.dart';

/// Approximates the RGB color of black-body light at [kelvin], for UI
/// previews (gradients, color dots). Based on Tanner Helland's fit.
Rgb kelvinToRgb(int kelvin) {
  final t = kelvin.clamp(1000, 40000) / 100.0;
  double red;
  double green;
  double blue;

  if (t <= 66) {
    red = 255;
    green = 99.4708025861 * math.log(t) - 161.1195681661;
  } else {
    red = 329.698727446 * math.pow(t - 60, -0.1332047592);
    green = 288.1221695283 * math.pow(t - 60, -0.0755148492);
  }

  if (t >= 66) {
    blue = 255;
  } else if (t <= 19) {
    blue = 0;
  } else {
    blue = 138.5177312231 * math.log(t - 10) - 305.0447927307;
  }

  int c(double v) => v.round().clamp(0, 255);
  return Rgb(c(red), c(green), c(blue));
}
