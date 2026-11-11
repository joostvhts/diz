import 'package:flutter/material.dart';

/// A slider whose track is a color gradient (used for brightness and color
/// temperature). Reports whole numbers.
class GradientSlider extends StatelessWidget {
  const GradientSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.colors,
    required this.onChanged,
    this.onChangeEnd,
    this.step = 1,
    this.label,
    this.semanticLabel,
  });

  final int value;
  final int min;
  final int max;
  final List<Color> colors;
  final int step;

  /// Null disables the slider.
  final ValueChanged<int>? onChanged;
  final ValueChanged<int>? onChangeEnd;
  final String Function(int value)? label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final theme = SliderTheme.of(context);
    final divisions = ((max - min) / step).round();
    final slider = SliderTheme(
      data: theme.copyWith(
        trackHeight: 14,
        trackShape: _GradientTrackShape(
          LinearGradient(colors: enabled ? colors : [for (final c in colors) c.withValues(alpha: 0.3)]),
          // Keeps light/dark gradient ends visible on both themes.
          Theme.of(context).colorScheme.outlineVariant,
        ),
        thumbColor: Colors.white,
        overlayColor: Colors.white.withValues(alpha: 0.2),
        thumbShape: const _OutlinedThumb(),
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      child: Slider(
        value: value.clamp(min, max).toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: divisions > 0 ? divisions : null,
        label: label?.call(value),
        semanticFormatterCallback: label == null ? null : (v) => label!(v.round()),
        onChanged: onChanged == null ? null : (v) => onChanged!(v.round()),
        onChangeEnd: onChangeEnd == null ? null : (v) => onChangeEnd!(v.round()),
      ),
    );
    return semanticLabel == null ? slider : Semantics(label: semanticLabel, child: slider);
  }
}

class _GradientTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const _GradientTrackShape(this.gradient, this.borderColor);

  final Gradient gradient;
  final Color borderColor;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    context.canvas
      ..drawRRect(rrect, Paint()..shader = gradient.createShader(rect, textDirection: textDirection))
      ..drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = borderColor,
      );
  }
}

class _OutlinedThumb extends SliderComponentShape {
  const _OutlinedThumb();

  static const double _radius = 13;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.fromRadius(_radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    canvas.drawCircle(center.translate(0, 1), _radius, Paint()..color = Colors.black26);
    canvas.drawCircle(center, _radius, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      _radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black12,
    );
  }
}
