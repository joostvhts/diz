import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../state/lights_controller.dart';
import 'control_panel.dart';

/// Shows the [ControlPanel] for [target] in a modal bottom sheet (phones).
Future<void> showControlSheet(
  BuildContext context, {
  required LightsController controller,
  required String target,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ControlSheet(controller: controller, target: target),
  );
}

/// The bottom sheet around a [ControlPanel] on phones.
///
/// It opens at the panel's own height. Swiping up makes it full screen;
/// swiping down returns to the panel's height and then closes it. The panel's
/// height changes with its tab (White or Color), and the sheet follows it
/// unless it is full screen.
///
/// The sheet runs under Android's navigation bar, so the panel gets that much
/// padding at the bottom.
class ControlSheet extends StatefulWidget {
  const ControlSheet({super.key, required this.controller, required this.target});

  final LightsController controller;
  final String target;

  @override
  State<ControlSheet> createState() => _ControlSheetState();
}

class _ControlSheetState extends State<ControlSheet> {
  // Fractions closer than this count as the same sheet size.
  static const _tolerance = 0.005;

  final _sheet = DraggableScrollableController();

  /// The height of the handle, panel and bottom padding, once laid out.
  double? _contentHeight;

  /// [_contentHeight] as a fraction of the available height: the size the
  /// sheet opens at and returns to.
  double? _fit;

  /// The sheet re-snaps whenever it gets a different list, so this stays the
  /// same object until [_fit] changes.
  List<double>? _snapSizes;

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  bool get _expanded => _fit != null && _sheet.isAttached && _sheet.size > _fit! + _tolerance;

  void _setContentHeight(double height) {
    if (mounted && height != _contentHeight) setState(() => _contentHeight = height);
  }

  void _updateFit(double? fit) {
    final old = _fit;
    if (old == fit || (old != null && fit != null && (old - fit).abs() < _tolerance)) return;
    _fit = fit;
    _snapSizes = fit != null && fit < 1 - _tolerance ? [fit] : null;

    // Follow the panel's new height if the sheet was at the old one. This runs
    // before the sheet's own re-snap to the nearest size (scheduled when it
    // gets the new snap sizes), which then stays here.
    if (old != null && fit != null && _sheet.isAttached && (_sheet.size - old).abs() < _tolerance) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sheet.isAttached) _sheet.jumpTo(fit);
      });
    }
  }

  void _toggle() {
    final fit = _fit;
    if (fit == null || fit >= 1 - _tolerance || !_sheet.isAttached) return;
    _sheet.animateTo(
      _expanded ? fit : 1,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentHeight = _contentHeight;
        _updateFit(
          contentHeight == null ? null : math.min(contentHeight / constraints.maxHeight, 1.0),
        );
        return DraggableScrollableSheet(
          controller: _sheet,
          expand: false,
          // Before the first layout the panel's height is unknown. That frame
          // is still below the screen, at the start of the opening animation.
          initialChildSize: _fit ?? 0.5,
          minChildSize: 0,
          snap: true,
          snapSizes: _snapSizes,
          builder: (context, scrollController) => SingleChildScrollView(
            controller: scrollController,
            child: _HeightReporter(
              onHeight: _setContentHeight,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Inside the scroll view, so dragging it resizes the sheet.
                  _DragHandle(onTap: _toggle),
                  ControlPanel(controller: widget.controller, target: widget.target),
                  SizedBox(height: bottomInset),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Looks like the bottom sheet's own drag handle. Tapping it switches between
/// the panel's height and full screen.
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = theme.bottomSheetTheme.dragHandleSize ?? const Size(32, 4);
    return Semantics(
      button: true,
      label: 'Resize the controls',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color:
                    theme.bottomSheetTheme.dragHandleColor ??
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(size.height / 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports its child's height after every layout in which it changed.
class _HeightReporter extends SingleChildRenderObjectWidget {
  const _HeightReporter({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderHeightReporter renderObject) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // Layout can't change widget state; the next frame picks it up.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}
