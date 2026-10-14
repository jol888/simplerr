import 'package:flutter/material.dart';

import '../algo/estimator.dart';
import '../settings.dart';

const appVersion = '0.2.0';

class SettingsPage extends StatelessWidget {
  final SettingsStore store;

  const SettingsPage({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ValueListenableBuilder<AppSettings>(
        valueListenable: store,
        builder: (context, s, _) {
          String bpm(double v) => v.toStringAsFixed(v % 1 == 0 ? 0 : 1);
          final slowWarning = 3 * 60 / s.minRateBpm > s.windowSec;
          return ListView(
            children: [
              const _Section('测量'),
              _Choice<double>(
                title: '分析窗口',
                help: '越长越稳、对节奏变化反应越慢。一个窗口至少要装下约 3 次呼吸。',
                value: s.windowSec,
                options: {
                  30.0: '30 秒',
                  45.0: '45 秒',
                  60.0: '60 秒',
                  90.0: '90 秒'
                },
                onChanged: (v) => store.update(s.copyWith(windowSec: v)),
              ),
              _Choice<double>(
                title: '最低呼吸率',
                help: '低于此值的呼吸测不到；设得越低，越容易受体位缓慢变化干扰。',
                value: s.minRateBpm,
                options: {
                  for (final v in const [2.4, 3.0, 4.2, 6.0])
                    v: '${bpm(v)} 次/分',
                },
                onChanged: (v) => store.update(s.copyWith(minRateBpm: v)),
              ),
              if (slowWarning)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '提示：${bpm(s.minRateBpm)} 次/分时一次呼吸 '
                    '${(60 / s.minRateBpm).toStringAsFixed(0)} 秒，'
                    '${s.windowSec.toStringAsFixed(0)} 秒窗口装不下 3 次，'
                    '最慢的呼吸可能测不准。',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              _Choice<double>(
                title: '读数平滑',
                help: '大数字显示最近这段时间有效估计的中位数。',
                value: s.smoothingSec,
                options: {5.0: '5 秒', 15.0: '15 秒', 30.0: '30 秒'},
                onChanged: (v) => store.update(s.copyWith(smoothingSec: v)),
              ),
              _Choice<double>(
                title: '移动容忍度',
                help: '越宽松，越不容易因小动作判为"移动"而暂停计数，但误差可能变大。',
                value: s.motionTolerance,
                options: {0.5: '严格', 1.0: '标准', 2.0: '宽松'},
                onChanged: (v) => store.update(s.copyWith(motionTolerance: v)),
              ),
              _Choice<int>(
                title: '采样率',
                help: '只影响录制的原始数据，呼吸分析都在 10 Hz 下进行。',
                value: s.samplingMs,
                options: const {20: '50 Hz', 10: '100 Hz'},
                onChanged: (v) => store.update(s.copyWith(samplingMs: v)),
              ),
              const _Section('外观'),
              _Choice<ThemeMode>(
                title: '主题',
                value: s.themeMode,
                options: const {
                  ThemeMode.system: '跟随系统',
                  ThemeMode.light: '浅色',
                  ThemeMode.dark: '深色',
                },
                onChanged: (v) => store.update(s.copyWith(themeMode: v)),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('恢复默认设置'),
                onTap: () => store.update(const AppSettings()),
              ),
              const _Section('关于'),
              ListTile(
                title: const Text('simplerr'),
                subtitle:
                    Text('版本 $appVersion · 算法 ${RespirationEstimator.version}\n'
                        '新设置从下一次测量开始生效；历史记录可选择用当前设置重新分析。\n'
                        '不是医疗器械，结果仅供参考。'),
                isThreeLine: true,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;

  const _Section(this.title);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold)),
      );
}

class _Choice<T> extends StatelessWidget {
  final String title;
  final String? help;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  const _Choice({
    required this.title,
    this.help,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  Future<void> _pick(BuildContext context) async {
    final v = await showDialog<T>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          if (help != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(help!, style: Theme.of(context).textTheme.bodySmall),
            ),
          for (final MapEntry(:key, value: label) in options.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, key),
              child: Row(
                children: [
                  Icon(key == value ? Icons.check : null, size: 20),
                  const SizedBox(width: 12),
                  Text(label),
                ],
              ),
            ),
        ],
      ),
    );
    if (v != null) onChanged(v);
  }

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(title),
        subtitle: Text(options[value] ?? '$value'),
        onTap: () => _pick(context),
      );
}
