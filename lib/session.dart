import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'algo/estimator.dart';
import 'algo/imu.dart';
import 'algo/pipeline.dart';
import 'algo/rec_format.dart';
import 'algo/tracker.dart';
import 'settings.dart';
import 'storage.dart';

/// Full estimates (with waveforms) kept for the cursor.
const _keepEstimates = 600;

/// One measurement session: streams sensors, writes the raw CSV, and runs the
/// pipeline once per second on a rolling buffer.
class Session extends ChangeNotifier {
  AppSettings settings;
  late Pipeline pipeline = _newPipeline();

  bool running = false;
  String? id;
  int accCount = 0, gyroCount = 0;
  double elapsedSec = 0;

  final _buf = ImuRecording([], []);
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _timer;
  CsvWriter? _writer;
  int _t0Us = 0;
  DateTime? _startedAt;

  Session(this.settings);

  Pipeline _newPipeline() =>
      Pipeline(settings.estimatorConfig, settings.trackerConfig,
          keepEstimates: _keepEstimates);

  EstimatorConfig get cfg => pipeline.estimator.cfg;
  double get accRateHz => elapsedSec > 0 ? accCount / elapsedSec : 0;
  double get gyroRateHz => elapsedSec > 0 ? gyroCount / elapsedSec : 0;

  Future<void> start() async {
    if (running) return;
    final now = DateTime.now();
    id = recordingId(now);
    _startedAt = now;
    _t0Us = now.microsecondsSinceEpoch;
    _writer = CsvWriter(await Storage.csvFile(id!));
    _buf.acc.clear();
    _buf.gyro.clear();
    pipeline = _newPipeline();
    accCount = gyroCount = 0;
    elapsedSec = 0;
    running = true;

    final period = Duration(milliseconds: settings.samplingMs);
    _accSub = accelerometerEventStream(samplingPeriod: period)
        .listen((e) => _add('a', _buf.acc, e.timestamp, e.x, e.y, e.z));
    _gyroSub = gyroscopeEventStream(samplingPeriod: period).listen(
      (e) => _add('g', _buf.gyro, e.timestamp, e.x, e.y, e.z),
      onError: (_) {},
    );
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    await WakelockPlus.enable();
    notifyListeners();
  }

  void _add(String sensor, List<ImuSample> list, DateTime ts, double x,
      double y, double z) {
    final t = ts.microsecondsSinceEpoch - _t0Us;
    if (t < 0) return;
    final s = ImuSample(t, x, y, z);
    list.add(s);
    _writer?.add(sensor, s);
    if (sensor == 'a') {
      accCount++;
    } else {
      gyroCount++;
    }
  }

  void _tick() {
    elapsedSec = (DateTime.now().microsecondsSinceEpoch - _t0Us) / 1e6;
    if (_buf.acc.isNotEmpty) {
      final tEnd = _buf.acc.last.tUs;
      final keepFrom = tEnd - ((cfg.windowSec + 5) * 1e6).round();
      for (final l in [_buf.acc, _buf.gyro]) {
        final i = lowerBound(l, keepFrom);
        if (i > 0) l.removeRange(0, i);
      }
      pipeline.step(_buf, tEnd);
    }
    notifyListeners();
  }

  /// Stops sensors and returns the metadata skeleton (caller adds labels).
  Future<RecordingMeta?> stop() async {
    if (!running) return null;
    running = false;
    await _accSub?.cancel();
    await _gyroSub?.cancel();
    _timer?.cancel();
    if (_buf.acc.isNotEmpty) pipeline.finish(_buf, _buf.acc.last.tUs);
    await _writer?.close();
    _writer = null;
    await WakelockPlus.disable();

    final history = pipeline.history;
    final valid = history.where((p) => p.valid).map((p) => p.bpm).toList()
      ..sort();
    final meta = RecordingMeta({
      'format': formatVersion,
      'id': id,
      'startedAt': _startedAt!.toIso8601String(),
      'durationSec': elapsedSec,
      'samplingPeriodMs': settings.samplingMs,
      'samples': {'acc': accCount, 'gyro': gyroCount},
      'device': await _deviceInfo(),
      'algo': {
        'version': RespirationEstimator.version,
        'config': cfg.toJson(),
        'liveMedianBpm': valid.isEmpty ? null : valid[valid.length ~/ 2],
        'counter': pipeline.counter.toJson(),
        'tracker': {
          'version': RateTracker.version,
          'config': pipeline.tracker.cfg.toJson(),
          'medianTrackedBpm': pipeline.medianTracked,
        },
      },
      'label': <String, dynamic>{},
    });
    await meta.save(await Storage.metaFile(id!));
    notifyListeners();
    return meta;
  }

  Future<Map<String, Object?>> _deviceInfo() async {
    if (!Platform.isAndroid) return {'os': Platform.operatingSystemVersion};
    final a = await DeviceInfoPlugin().androidInfo;
    return {
      'manufacturer': a.manufacturer,
      'model': a.model,
      'sdkInt': a.version.sdkInt,
      'release': a.version.release,
    };
  }

  @override
  void dispose() {
    _accSub?.cancel();
    _gyroSub?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}
