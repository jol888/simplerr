import 'package:flutter/material.dart';

import '../algo/estimator.dart';
import '../algo/rec_format.dart';
import '../session.dart';
import '../storage.dart';
import 'charts.dart';
import 'label_dialog.dart';
import 'recordings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final session = Session();
  double? _cursorT;

  /// Seconds of the session where breaths couldn't be counted.
  double _uncounted() =>
      session.counter.uncountedUs((session.elapsedSec * 1e6).round()) / 1e6;

  BpmPoint? _nearest(double t) {
    BpmPoint? best;
    for (final p in session.history) {
      if (best == null || (p.tSec - t).abs() < (best.tSec - t).abs()) best = p;
    }
    return best;
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!session.running) {
      setState(() => _cursorT = null);
      await session.start();
      return;
    }
    final meta = await session.stop();
    if (meta == null || !mounted) return;
    final label = await showLabelDialog(context, meta);
    if (label != null) {
      meta.json['label'] = label;
      await meta.save(await Storage.metaFile(meta.id));
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已保存 rec_${meta.id}')));
    }
  }

  String _status(Estimate? e) {
    if (!session.running) return '平躺，手机放在胸口或腹部，点开始';
    if (e == null) {
      final left = session.estimator.cfg.minWindowSec - session.elapsedSec;
      return '采集中，${left.ceil().clamp(0, 999)} 秒后出结果';
    }
    if (e.motion) return '检测到移动，请保持静止';
    if (!e.valid) {
      return '信号弱（质量 ${e.quality.toStringAsFixed(2)}，'
          'SNR ${e.best.snrDb.toStringAsFixed(0)} dB）';
    }
    return '信号良好';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('呼吸监测'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '录制记录',
            onPressed: session.running
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RecordingsPage())),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final e = session.latest;
          final bpm = session.tracked;
          final cursor = _cursorT == null ? null : _nearest(_cursorT!);
          final shown = cursor == null ? e : session.estimateAt(cursor.tSec);
          final small = Theme.of(context).textTheme.bodySmall;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: Text(
                  bpm == null ? '--' : bpm.toStringAsFixed(1),
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: bpm == null ? Colors.grey : scheme.primary),
                ),
              ),
              Center(
                child: Text(e == null
                    ? '次/分钟（${session.tracker.cfg.spanSec.toStringAsFixed(0)} s 中位数）'
                    : '次/分钟 · 本窗口 ${e.bpmSpectral.toStringAsFixed(1)}'),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                    '累计 ${session.counter.total} 次呼吸'
                    '${_uncounted() >= 1 ? ' · ${_uncounted().toStringAsFixed(0)} s 未计' : ''}',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              const SizedBox(height: 8),
              Center(child: Text(_status(e))),
              const SizedBox(height: 16),
              Text(
                  cursor == null
                      ? '波形（最近 ${session.estimator.cfg.windowSec.toStringAsFixed(0)} s）'
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
                    void set(Offset p) =>
                        setState(() => _cursorT = TrendPainter.timeAt(
                            session.history, p.dx, box.maxWidth));
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => set(d.localPosition),
                      onHorizontalDragStart: (d) => set(d.localPosition),
                      onHorizontalDragUpdate: (d) => set(d.localPosition),
                      child: CustomPaint(
                          painter: TrendPainter(session.history, scheme.primary,
                              cursorT: cursor?.tSec),
                          size: Size.infinite),
                    );
                  },
                ),
              ),
              if (cursor != null)
                _CursorInfo(
                    p: cursor, onClose: () => setState(() => _cursorT = null)),
              const SizedBox(height: 16),
              _Details(session: session),
            ],
          );
        },
      ),
      floatingActionButton: ListenableBuilder(
        listenable: session,
        builder: (context, _) => FloatingActionButton.extended(
          onPressed: _toggle,
          icon: Icon(session.running ? Icons.stop : Icons.play_arrow),
          label: Text(session.running ? '停止' : '开始'),
        ),
      ),
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

class _Details extends StatelessWidget {
  final Session session;

  const _Details({required this.session});

  @override
  Widget build(BuildContext context) {
    final e = session.latest;
    String f(double v, [int d = 1]) => v.isNaN ? '-' : v.toStringAsFixed(d);
    final rows = <(String, String)>[
      ('时长', '${session.elapsedSec.toStringAsFixed(0)} s'),
      (
        '采样率',
        'acc ${f(session.accRateHz)} Hz · gyro ${f(session.gyroRateHz)} Hz'
      ),
      if (e != null) ...[
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
      ],
      ('算法', RespirationEstimator.version),
      ('格式', 'v$formatVersion'),
    ];
    return Column(
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
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
