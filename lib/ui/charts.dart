import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../algo/estimator.dart';
import '../session.dart';

/// Filtered signal of the selected channel, with detected breath onsets.
class WaveformPainter extends CustomPainter {
  final Estimate? est;
  final Color color;

  WaveformPainter(this.est, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final e = est;
    final axis = Paint()
      ..color = Colors.grey.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(0, size.height / 2), Offset(size.width, size.height / 2), axis);
    if (e == null) return;
    final x = e.best.signal;
    if (x.length < 2) return;
    var amp = 0.0;
    for (final v in x) {
      amp = math.max(amp, v.abs());
    }
    if (amp == 0) amp = 1;
    final path = Path();
    for (var i = 0; i < x.length; i++) {
      final px = i / (x.length - 1) * size.width;
      final py = size.height / 2 - x[i] / amp * size.height * 0.45;
      i == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    final span = (e.tEndUs - e.tStartUs).toDouble();
    final mark = Paint()
      ..color = Colors.orange
      ..strokeWidth = 1.5;
    for (final t in e.breathTimesUs) {
      final px = (t - e.tStartUs) / span * size.width;
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), mark);
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) => old.est != est;
}

/// Rate history: raw per-window estimates as dots (grey = invalid), tracked
/// rate as a line, optional vertical cursor.
class TrendPainter extends CustomPainter {
  final List<BpmPoint> points;
  final Color color;
  final double? cursorT;
  final int length;

  TrendPainter(this.points, this.color, {this.cursorT})
      : length = points.length;

  /// Time span shown on the x axis.
  static (double, double) range(List<BpmPoint> points) {
    if (points.isEmpty) return (0, 60);
    final t0 = points.first.tSec;
    return (t0, math.max(points.last.tSec, t0 + 60));
  }

  static double timeAt(List<BpmPoint> points, double dx, double width) {
    final (t0, t1) = range(points);
    return t0 + (dx / width).clamp(0.0, 1.0) * (t1 - t0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const lo = 0.0;
    var top = 0.0;
    for (final p in points) {
      if (p.valid) top = math.max(top, p.bpm);
      if (p.tracked != null) top = math.max(top, p.tracked!);
    }
    final step = top <= 18 ? 3.0 : (top <= 36 ? 6.0 : 10.0);
    final hi = math.max(12.0, (top / step).ceil() * step + step);
    final grid = Paint()
      ..color = Colors.grey.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var v = step; v < hi; v += step) {
      final y = size.height * (1 - (v - lo) / (hi - lo));
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      tp.text = TextSpan(
          text: v.toStringAsFixed(0),
          style: const TextStyle(fontSize: 10, color: Colors.grey));
      tp.layout();
      tp.paint(canvas, Offset(2, y - 12));
    }
    if (points.isEmpty) return;
    final (t0, t1) = range(points);
    double px(double t) => (t - t0) / (t1 - t0) * size.width;
    double py(double bpm) =>
        size.height * (1 - (bpm.clamp(lo, hi) - lo) / (hi - lo));
    final ok = Paint()..color = color.withValues(alpha: 0.45);
    final bad = Paint()..color = Colors.grey.withValues(alpha: 0.5);
    for (final p in points) {
      canvas.drawCircle(Offset(px(p.tSec), py(p.bpm)), p.valid ? 2.5 : 1.5,
          p.valid ? ok : bad);
    }
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    Path? path;
    for (final p in points) {
      final v = p.tracked;
      if (v == null) {
        if (path != null) canvas.drawPath(path, line);
        path = null;
        continue;
      }
      final o = Offset(px(p.tSec), py(v));
      if (path == null) {
        path = Path()..moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    if (path != null) canvas.drawPath(path, line);

    final c = cursorT;
    if (c != null) {
      final x = px(c);
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = Colors.red
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(TrendPainter old) =>
      old.length != points.length || old.cursorT != cursorT;
}
