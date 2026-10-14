import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'algo/estimator.dart';
import 'algo/tracker.dart';

/// User-facing settings; mapped onto the algorithm configs for new sessions
/// and for history review with "current settings".
class AppSettings {
  final double windowSec;

  /// Lowest rate the band covers, breaths/min (sets the high-pass cutoff).
  final double minRateBpm;
  final double smoothingSec;
  final int samplingMs;

  /// Multiplier on the motion thresholds; larger = tolerates more movement.
  final double motionTolerance;
  final ThemeMode themeMode;

  const AppSettings({
    this.windowSec = 60,
    this.minRateBpm = 2.4,
    this.smoothingSec = 15,
    this.samplingMs = 20,
    this.motionTolerance = 1,
    this.themeMode = ThemeMode.system,
  });

  EstimatorConfig get estimatorConfig {
    const d = EstimatorConfig();
    return EstimatorConfig.fromJson({
      ...d.toJson(),
      'windowSec': windowSec,
      'minWindowSec': windowSec < d.minWindowSec ? windowSec : d.minWindowSec,
      'fLow': minRateBpm / 60,
      'motionAccStd': d.motionAccStd * motionTolerance,
      'motionGyroMax': d.motionGyroMax * motionTolerance,
    });
  }

  TrackerConfig get trackerConfig => TrackerConfig.span(smoothingSec);

  AppSettings copyWith({
    double? windowSec,
    double? minRateBpm,
    double? smoothingSec,
    int? samplingMs,
    double? motionTolerance,
    ThemeMode? themeMode,
  }) =>
      AppSettings(
        windowSec: windowSec ?? this.windowSec,
        minRateBpm: minRateBpm ?? this.minRateBpm,
        smoothingSec: smoothingSec ?? this.smoothingSec,
        samplingMs: samplingMs ?? this.samplingMs,
        motionTolerance: motionTolerance ?? this.motionTolerance,
        themeMode: themeMode ?? this.themeMode,
      );

  Map<String, Object> toJson() => {
        'windowSec': windowSec,
        'minRateBpm': minRateBpm,
        'smoothingSec': smoothingSec,
        'samplingMs': samplingMs,
        'motionTolerance': motionTolerance,
        'themeMode': themeMode.name,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    const d = AppSettings();
    double g(String k, double v) => (j[k] as num?)?.toDouble() ?? v;
    return AppSettings(
      windowSec: g('windowSec', d.windowSec),
      minRateBpm: g('minRateBpm', d.minRateBpm),
      smoothingSec: g('smoothingSec', d.smoothingSec),
      samplingMs: (j['samplingMs'] as num?)?.toInt() ?? d.samplingMs,
      motionTolerance: g('motionTolerance', d.motionTolerance),
      themeMode: ThemeMode.values.asNameMap()[j['themeMode']] ?? d.themeMode,
    );
  }
}

class SettingsStore extends ValueNotifier<AppSettings> {
  static const _key = 'settings';

  SettingsStore() : super(const AppSettings());

  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return;
    try {
      value = AppSettings.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>());
    } on FormatException {
      value = const AppSettings();
    }
  }

  Future<void> update(AppSettings s) async {
    value = s;
    await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode(s.toJson()));
  }
}
