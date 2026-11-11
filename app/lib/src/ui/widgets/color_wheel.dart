import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A hue/saturation color wheel: hue around the circle, saturation from the
/// white center to the edge. Brightness is controlled separately, like in
/// the WiZ app.
class ColorWheel extends StatefulWidget {
  const ColorWheel({
    super.key,
    required this.color,
    required this.onChanged,
    this.onChangeEnd,
    this.maxSize = 280,
  });

  /// Currently selected color, or null to hide the marker.
  final Color? color;

  /// Null disables the wheel.
  final ValueChanged<Color>? onChanged;
  final ValueChanged<Color>? onChangeEnd;
  final double maxSize;

  @override
  State<ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<ColorWheel> {
  Color? _last;

  @override
  Widget build(BuildContext context) {
    final color = widget.color;
    return LayoutBuilder(builder: (context, constraints) {
      final size = math.min(constraints.maxWidth, widget.maxSize);
      final radius = size / 2;

      Color colorAt(Offset local) {
        final dx = local.dx - radius;
        final dy = local.dy - radius;
        final saturation = (math.sqrt(dx * dx + dy * dy) / radius).clamp(0.0, 1.0);
        final hue = (math.atan2(dy, dx) * 180 / math.pi + 360) % 360;
        return HSVColor.fromAHSV(1, hue, saturation, 1).toColor();
      }

      void update(Offset local) {
        final picked = _last = colorAt(local);
        widget.onChanged?.call(picked);
      }

      void end() {
        final picked = _last;
        if (picked != null) widget.onChangeEnd?.call(picked);
        _last = null;
      }

      final enabled = widget.onChanged != null;
      return Center(
        child: Semantics(
          label: 'Color wheel',
          child: GestureDetector(
            onPanStart: enabled ? (d) => update(d.localPosition) : null,
            onPanUpdate: enabled ? (d) => update(d.localPosition) : null,
            onPanEnd: enabled ? (_) => end() : null,
            onTapUp: enabled
                ? (d) {
                    update(d.localPosition);
                    end();
                  }
                : null,
            child: Opacity(
              opacity: enabled ? 1 : 0.4,
              child: CustomPaint(
                size: Size.square(size),
                painter: _WheelPainter(color),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _WheelPainter extends CustomPainter {
  _WheelPainter(this.selected);

  final Color? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final center = Offset(radius, radius);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final hues = [for (var h = 0; h <= 360; h += 30) HSVColor.fromAHSV(1, h % 360, 1, 1).toColor()];
    canvas.drawCircle(center, radius, Paint()..shader = SweepGradient(colors: hues).createShader(rect));
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(colors: [Colors.white, Colors.white.withValues(alpha: 0)])
            .createShader(rect),
    );

    final color = selected;
    if (color == null) return;
    final hsv = HSVColor.fromColor(color);
    final angle = hsv.hue * math.pi / 180;
    final distance = hsv.saturation * radius;
    final marker = center + Offset(math.cos(angle) * distance, math.sin(angle) * distance);
    canvas.drawCircle(marker.translate(0, 1.5), 15, Paint()..color = Colors.black26);
    canvas.drawCircle(marker, 15, Paint()..color = Colors.white);
    canvas.drawCircle(marker, 11, Paint()..color = HSVColor.fromAHSV(1, hsv.hue, hsv.saturation, 1).toColor());
  }

  @override
  bool shouldRepaint(_WheelPainter oldDelegate) => oldDelegate.selected != selected;
}
