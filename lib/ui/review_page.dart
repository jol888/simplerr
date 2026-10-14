import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../algo/estimator.dart';
import '../algo/pipeline.dart';
import '../algo/rec_format.dart';
import '../algo/tracker.dart';
import '../settings.dart';
import '../storage.dart';
import 'analysis_view.dart';
import 'label_dialog.dart';
import 'recordings_page.dart';

/// Re-analyses a saved recording with the same pipeline used live.
class ReviewPage extends StatefulWidget {
  final RecordingEntry entry;
  final SettingsStore settings;

  const ReviewPage({super.key, required this.entry, required this.settings});

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

enum _Params { recorded, current }

/// Top-level so the isolate closure captures nothing from widget state.
Future<(Pipeline, double)> _analyze(
    String path, EstimatorConfig ecfg, TrackerConfig tcfg, double step) {
  return Isolate.run(() async {
    final rec = parseCsv(await File(path).readAsString());
    return (Pipeline.replay(rec, ecfg, tcfg, stepSec: step), step);
  });
}

class _ReviewPageState extends State<ReviewPage> {
  late RecordingMeta? _meta = widget.entry.data;
  late _Params _params =
      _recordedConfig() == null ? _Params.current : _Params.recorded;
  Future<(Pipeline, double)>? _result;

  @override
  void initState() {
    super.initState();
    _run();
  }

  (EstimatorConfig, TrackerConfig)? _recordedConfig() {
    final algo = (_meta?.json['algo'] as Map?)?.cast<String, dynamic>();
    final ecfg = (algo?['config'] as Map?)?.cast<String, dynamic>();
    if (ecfg == null) return null;
    final tcfg = ((algo?['tracker'] as Map?)?['config'] as Map?)
        ?.cast<String, dynamic>();
    return (
      EstimatorConfig.fromJson(ecfg),
      tcfg == null ? const TrackerConfig() : TrackerConfig.fromJson(tcfg),
    );
  }

  void _run() {
    final s = widget.settings.value;
    final (ecfg, tcfg) = _params == _Params.recorded
        ? _recordedConfig()!
        : (s.estimatorConfig, s.trackerConfig);
    final path = widget.entry.csv.path;
    final dur = _meta?.durationSec ?? 0;
    // Keep roughly ≤ 900 windows so long recordings stay quick.
    final step = dur <= 900 ? 1.0 : (dur / 900).ceilToDouble();
    setState(() => _result = _analyze(path, ecfg, tcfg, step));
  }

  Future<void> _editLabel() async {
    final m = _meta;
    if (m == null) return;
    final label = await showLabelDialog(context, m);
    if (label == null) return;
    m.json['label'] = label;
    await m.save(widget.entry.meta);
    setState(() => _meta = m);
  }

  Future<void> _share() async {
    final e = widget.entry;
    await SharePlus.instance.share(ShareParams(files: [
      XFile(e.csv.path, mimeType: 'text/csv'),
      if (e.meta.existsSync()) XFile(e.meta.path, mimeType: 'application/json'),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta;
    return Scaffold(
      appBar: AppBar(
        title: Text(prettyId(widget.entry.id)),
        actions: [
          IconButton(
              icon: const Icon(Icons.edit_note),
              tooltip: '修改标注',
              onPressed: m == null ? null : _editLabel),
          IconButton(
              icon: const Icon(Icons.share), tooltip: '导出', onPressed: _share),
        ],
      ),
      body: FutureBuilder<(Pipeline, double)>(
        future: _result,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('分析失败：${snap.error}'));
          }
          final r = snap.data;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SegmentedButton<_Params>(
                segments: const [
                  ButtonSegment(value: _Params.recorded, label: Text('录制时参数')),
                  ButtonSegment(value: _Params.current, label: Text('当前设置')),
                ],
                selected: {_params},
                onSelectionChanged: snap.connectionState == ConnectionState.done
                    ? (v) {
                        if (v.first == _Params.recorded &&
                            _recordedConfig() == null) {
                          return;
                        }
                        _params = v.first;
                        _run();
                      }
                    : null,
              ),
              const SizedBox(height: 16),
              if (r == null)
                const Padding(
                  padding: EdgeInsets.all(48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                ..._body(r.$1, r.$2, m),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _body(Pipeline p, double step, RecordingMeta? m) {
    final dur = m?.durationSec ?? (p.history.isEmpty ? 0 : p.history.last.tSec);
    final manual = m?.manualCount;
    final validPct = p.history.isEmpty
        ? 0
        : 100 * p.history.where((x) => x.valid).length / p.history.length;
    final cfg = p.estimator.cfg;
    final recordedVersion = (m?.json['algo'] as Map?)?['version'] as String?;
    final dev = (m?.json['device'] as Map?)?.cast<String, dynamic>();
    return [
      RateHeader(
        bpm: p.medianTracked,
        subtitle: '次/分钟（全程平滑中位数）',
        total: p.counter.total,
        uncountedSec: p.counter.uncountedUs((dur * 1e6).round()) / 1e6,
      ),
      if (manual != null)
        Center(
          child: Text(
              '手数 $manual 次 · 差 ${p.counter.total - manual >= 0 ? '+' : ''}${p.counter.total - manual}'
              ' · 折合 ${m!.referenceBpm!.toStringAsFixed(1)} 次/分'),
        ),
      const SizedBox(height: 16),
      AnalysisView(
        key: ValueKey(_params),
        history: p.history,
        latest: p.latest,
        estimateAt: (t) => p.estimateAt(t, stepSec: step),
        latestLabel: '波形（最后一个窗口）',
      ),
      const SizedBox(height: 16),
      InfoRows([
        if (m != null) ('开始', m.json['startedAt'] as String? ?? '-'),
        ('时长', '${dur.toStringAsFixed(0)} s'),
        if (m != null && m.posture.isNotEmpty) ('姿势', m.posture),
        if (m != null && m.note.isNotEmpty) ('备注', m.note),
        if (dev != null) ('设备', '${dev['manufacturer']} ${dev['model']}'),
        ('有效窗口', '${validPct.toStringAsFixed(0)}%'),
        ('录制时算法', recordedVersion ?? '-'),
        ('当前算法', RespirationEstimator.version),
        (
          '分析参数',
          '窗口 ${cfg.windowSec.toStringAsFixed(0)} s · '
              '最低 ${(cfg.fLow * 60).toStringAsFixed(1)} 次/分 · '
              '平滑 ${p.tracker.cfg.spanSec.toStringAsFixed(0)} s'
              '${step > 1 ? ' · 步长 ${step.toStringAsFixed(0)} s' : ''}'
        ),
      ]),
    ];
  }
}
