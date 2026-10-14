import 'package:flutter/material.dart';

import '../algo/estimator.dart';
import '../algo/pipeline.dart';
import 'charts.dart';

/// Big tracked rate plus breath total; shared by live and review screens.
class RateHeader extends StatelessWidget {
  final double? bpm;
  final String subtitle;
  final int total;
  final double uncountedSec;

  const RateHeader({
    super.key,
    required this.bpm,
    required this.subtitle,
    required this.total,
    required this.uncountedSec,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = bpm;
    return Column(
      children: [
        Text(
          v == null ? '--' : v.toStringAsFixed(1),
          style: theme.textTheme.displayLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: v == null ? Colors.grey : theme.colorScheme.primary),
        ),
        Text(subtitle),
        const SizedBox(height: 4),
        Text(
          '累计 $total 次呼吸'
          '${uncountedSec >= 1 ? ' · ${uncountedSec.toStringAsFixed(0)} s 未计' : ''}',
          style: theme.textTheme.titleMedium,
        ),
      ],
    );
  }
}

/// Waveform + trend chart with a draggable cursor. When the cursor is set, the
/// waveform shows the window at the cursor instead of [latest].
class AnalysisView extends StatefulWidget {
  final List<BpmPoint> history;
  final Estimate? latest;
  final Estimate? Function(double tSec) estimateAt;
  final String latestLabel;

  const AnalysisView({
    super.key,
    required this.history,
    required this.latest,
    required this.estimateAt,
    required this.latestLabel,
  });

  @override
  State<AnalysisView> createState() => _AnalysisViewState();
}

class _AnalysisViewState extends State<AnalysisView> {
  double? _cursorT;

  BpmPoint? _nearest(double t) {
    BpmPoint? best;
    for (final p in widget.history) {
      if (best == null || (p.tSec - t).abs() < (best.tSec - t).abs()) best = p;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final cursor = _cursorT == null ? null : _nearest(_cursorT!);
    final shown =
        cursor == null ? widget.latest : widget.estimateAt(cursor.tSec);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
            cursor == null
                ? widget.latestLabel
                : shown == null
                    ? '波形 @ ${cursor.tSec.toStringAsFixed(0)} s（已不在缓存中）'
                    : '波形 @ ${(shown.tStartUs / 1e6).toStringAsFixed(0)}–'
                        '${(shown.tEndUs / 1e6).toStringAsFixed(0)} s',
            style: small),
        SizedBox(
          height: 140,
          child: CustomPaint(
              painter: WaveformPainter(shown, scheme.primary),
              size: Size.infinite),
        ),
        const SizedBox(height: 16),
        Text('趋势（点、拖动查看；点 = 单窗口，线 = 平滑）', style: small),
        SizedBox(
          height: 140,
          child: LayoutBuilder(
            builder: (context, box) {
              void set(Offset p) => setState(() => _cursorT =
                  TrendPainter.timeAt(widget.history, p.dx, box.maxWidth));
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => set(d.localPosition),
                onHorizontalDragStart: (d) => set(d.localPosition),
                onHorizontalDragUpdate: (d) => set(d.localPosition),
                child: CustomPaint(
                    painter: TrendPainter(widget.history, scheme.primary,
                        cursorT: cursor?.tSec),
                    size: Size.infinite),
              );
            },
          ),
        ),
        if (cursor != null)
          _CursorInfo(
              p: cursor, onClose: () => setState(() => _cursorT = null)),
      ],
    );
  }
}

class _CursorInfo extends StatelessWidget {
  final BpmPoint p;
  final VoidCallback onClose;

  const _CursorInfo({required this.p, required this.onClose});

  @override
  Widget build(BuildContext context) {
    String f(double? v, [int d = 1]) =>
        v == null || v.isNaN ? '-' : v.toStringAsFixed(d);
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                't = ${f(p.tSec, 0)} s · 累计 ${p.total} 次 · 平滑 ${f(p.tracked)} · '
                '窗口 ${f(p.bpm)} / 计数 ${f(p.bpmCount)}\n'
                '质量 ${f(p.quality, 2)} · SNR ${f(p.snrDb, 0)} dB · '
                '${p.channel} · ${p.valid ? '有效' : '无效'}',
              ),
            ),
            IconButton(icon: const Icon(Icons.close), onPressed: onClose),
          ],
        ),
      ),
    );
  }
}

/// Grey-key / value rows.
class InfoRows extends StatelessWidget {
  final List<(String, String)> rows;

  const InfoRows(this.rows, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                    width: 96,
                    child: Text(k, style: const TextStyle(color: Colors.grey))),
                Expanded(child: Text(v)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Diagnostic rows for one estimate.
List<(String, String)> estimateRows(Estimate e) {
  String f(double v, [int d = 1]) => v.isNaN ? '-' : v.toStringAsFixed(d);
  return [
    ('频谱 / 计数', '${f(e.bpmSpectral)} / ${f(e.bpmCount)} 次/分'),
    ('通道', '${e.best.name}（PCA 解释 ${f(e.best.explainedVar, 2)}）'),
    (
      '各通道质量',
      e.channels
          .map((c) => '${c.name} q${f(c.quality, 2)} ${f(c.snrDb, 0)}dB')
          .join(' · ')
    ),
    (
      '运动',
      'acc std ${f(e.motionAccStd, 3)} · gyro max ${f(e.motionGyroMax, 3)}'
    ),
  ];
}
