import 'dart:math';

import 'package:flutter/material.dart';

/// Material's indeterminate CircularProgressIndicator, with round ends, drawn so that it stays smooth
/// on Linux. There Flutter draws with Impeller on OpenGL, without multisampling, which leaves stroked
/// arcs and paths jagged but antialiases circles. So the arc is a whole circle that a sweep gradient
/// paints only along the arc, and its ends are small filled circles.
class Spinner extends StatefulWidget {
  const Spinner({this.size = 36, this.strokeWidth = 4, this.color, super.key});

  /// The circle's diameter, stroke included. Material's spinner's, by default.
  final double size;

  final double strokeWidth;

  /// The progress indicator theme's color, or the primary color, by default. Opaque: the ends paint
  /// over the arc.
  final Color? color;

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: _cycle)..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _SpinnerPainter(
          _controller,
          strokeWidth: widget.strokeWidth,
          color: widget.color ?? theme.progressIndicatorTheme.color ?? theme.colorScheme.primary,
        ),
      ),
    );
  }
}

// Material's timing: the arc grows and shrinks every 1333 ms while it turns once every 2222 ms. One
// cycle of the controller holds a whole number of both.
const _growth = 1333;
const _turn = 2222;
const _cycle = Duration(milliseconds: _growth * _turn);
const _head = Interval(0, 0.5, curve: Curves.fastOutSlowIn);
const _tail = Interval(0.5, 1, curve: Curves.fastOutSlowIn);

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter(this.animation, {required this.strokeWidth, required this.color}) : super(repaint: animation);

  final Animation<double> animation;
  final double strokeWidth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final elapsed = animation.value * _cycle.inMilliseconds;
    final growth = elapsed % _growth / _growth;
    final turn = elapsed % _turn / _turn;
    final head = _head.transform(growth);
    final tail = _tail.transform(growth);
    final start = -pi / 2 + tail * 3 / 2 * pi + turn * 2 * pi + growth * pi / 2;
    final sweep = (head - tail) * 3 / 2 * pi;

    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final along = sweep / (2 * pi);
    final arc = SweepGradient(
      colors: [color, color, color.withAlpha(0), color.withAlpha(0)],
      stops: [0, along, along, 1],
      transform: GradientRotation(start),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..shader = arc.createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    final end = Paint()..color = color;
    canvas.drawCircle(center + Offset.fromDirection(start, radius), strokeWidth / 2, end);
    canvas.drawCircle(center + Offset.fromDirection(start + sweep, radius), strokeWidth / 2, end);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) =>
      old.animation != animation || old.strokeWidth != strokeWidth || old.color != color;
}
