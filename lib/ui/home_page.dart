import 'package:flutter/material.dart';

import '../algo/estimator.dart';
import '../algo/rec_format.dart';
import '../session.dart';
import '../settings.dart';
import '../storage.dart';
import 'analysis_view.dart';
import 'label_dialog.dart';
import 'recordings_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  final SettingsStore settings;

  const HomePage({super.key, required this.settings});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final session = Session(widget.settings.value);

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (!session.running) {
      session.settings = widget.settings.value;
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
      final left = session.cfg.minWindowSec - session.elapsedSec;
      return '采集中，${left.ceil().clamp(0, 999)} 秒后出结果';
    }
    if (e.motion) return '检测到移动，请保持静止';
    if (!e.valid) {
      return '信号弱（质量 ${e.quality.toStringAsFixed(2)}，'
          'SNR ${e.best.snrDb.toStringAsFixed(0)} dB）';
    }
    return '信号良好';
  }

  void _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('simplerr'),
        actions: [
          ListenableBuilder(
            listenable: session,
            builder: (context, _) => Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.history),
                  tooltip: '历史记录',
                  onPressed: session.running
                      ? null
                      : () => _open(RecordingsPage(settings: widget.settings)),
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  tooltip: '设置',
                  onPressed: session.running
                      ? null
                      : () => _open(SettingsPage(store: widget.settings)),
                ),
              ],
            ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final p = session.pipeline;
          final e = p.latest;
          final elapsedUs = (session.elapsedSec * 1e6).round();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              RateHeader(
                bpm: p.tracked,
                subtitle: e == null
                    ? '次/分钟（${p.tracker.cfg.spanSec.toStringAsFixed(0)} s 中位数）'
                    : '次/分钟 · 本窗口 ${e.bpmSpectral.toStringAsFixed(1)}',
                total: p.counter.total,
                uncountedSec: p.counter.uncountedUs(elapsedUs) / 1e6,
              ),
              const SizedBox(height: 8),
              Center(child: Text(_status(e))),
              const SizedBox(height: 16),
              AnalysisView(
                key: ValueKey(session.id),
                history: p.history,
                latest: e,
                estimateAt: p.estimateAt,
                latestLabel:
                    '波形（最近 ${session.cfg.windowSec.toStringAsFixed(0)} s）',
              ),
              const SizedBox(height: 16),
              InfoRows([
                ('时长', '${session.elapsedSec.toStringAsFixed(0)} s'),
                (
                  '采样率',
                  'acc ${session.accRateHz.toStringAsFixed(1)} Hz · '
                      'gyro ${session.gyroRateHz.toStringAsFixed(1)} Hz'
                ),
                if (e != null) ...estimateRows(e),
                ('算法', RespirationEstimator.version),
                ('格式', 'v$formatVersion'),
              ]),
              const SizedBox(height: 72),
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
