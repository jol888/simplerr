import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'algo/breath_counter.dart';
import 'algo/estimator.dart';
import 'algo/imu.dart';
import 'algo/rec_format.dart';
import 'algo/tracker.dart';
import 'storage.dart';

const samplingPeriod = Duration(milliseconds: 20);

class BpmPoint {
  final double tSec, bpm, bpmCount, quality, snrDb;
  final bool valid;
  final String channel;

  /// Smoothed rate from [RateTracker], null while not enough valid estimates.
  final double? tracked;

  /// Breaths counted so far.
  final int total;

  BpmPoint(this.tSec, Estimate e, this.tracked, this.total)
      : bpm = e.bpmSpectral,
        bpmCount = e.bpmCount,
        quality = e.quality,
        snrDb = e.best.snrDb,
        valid = e.valid,
        channel = e.best.name;
}

/// Full estimates (with waveforms) kept for the cursor, newest last.
const _keepEstimates = 600;

/// One measurement session: streams sensors, writes the raw CSV, and runs the
/// estimator once per second on a rolling buffer.
class Session extends ChangeNotifier {
  final estimator = RespirationEstimator();
  final tracker = RateTracker();
  final counter = BreathCounter();

  bool running = false;
  String? id;
  Estimate? latest;
  double? tracked;
  final history = <BpmPoint>[];
  final _estimates = <Estimate>[];
  int accCount = 0, gyroCount = 0;
  double elapsedSec = 0;

  final _buf = ImuRecording([], []);
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _timer;
  CsvWriter? _writer;
  int _t0Us = 0;
  DateTime? _startedAt;

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
    history.clear();
    _estimates.clear();
    tracker.reset();
    counter.reset();
    latest = null;
    tracked = null;
    accCount = gyroCount = 0;
    elapsedSec = 0;
    running = true;

    _accSub = accelerometerEventStream(samplingPeriod: samplingPeriod)
        .listen((e) => _add('a', _buf.acc, e.timestamp, e.x, e.y, e.z));
    _gyroSub = gyroscopeEventStream(samplingPeriod: samplingPeriod).listen(
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
      final keepFrom = tEnd - ((estimator.cfg.windowSec + 5) * 1e6).round();
      for (final l in [_buf.acc, _buf.gyro]) {
        final i = lowerBound(l, keepFrom);
        if (i > 0) l.removeRange(0, i);
      }
      final est = estimator.estimate(_buf, tEnd);
      if (est != null) {
        latest = est;
        tracked = tracker.update(est);
        counter.update(est);
        history.add(BpmPoint(tEnd / 1e6, est, tracked, counter.total));
        _estimates.add(est);
        if (_estimates.length > _keepEstimates) _estimates.removeAt(0);
      }
    }
    notifyListeners();
  }

  /// Estimate whose window ends closest to [tSec], if still buffered.
  Estimate? estimateAt(double tSec) {
    Estimate? best;
    for (final e in _estimates) {
      if (best == null ||
          (e.tEndUs / 1e6 - tSec).abs() < (best.tEndUs / 1e6 - tSec).abs()) {
        best = e;
      }
    }
    return best != null && (best.tEndUs / 1e6 - tSec).abs() < 1.5 ? best : null;
  }

  /// Stops sensors and returns the metadata skeleton (caller adds labels).
  Future<RecordingMeta?> stop() async {
    if (!running) return null;
    running = false;
    await _accSub?.cancel();
    await _gyroSub?.cancel();
    _timer?.cancel();
    if (_buf.acc.isNotEmpty) {
      final last = estimator.estimate(_buf, _buf.acc.last.tUs);
      if (last != null) counter.finish(last);
    }
    await _writer?.close();
    _writer = null;
    await WakelockPlus.disable();

    final valid = history.where((p) => p.valid).map((p) => p.bpm).toList()
      ..sort();
    final trackedVals =
        history.map((p) => p.tracked).whereType<double>().toList()..sort();
    final meta = RecordingMeta({
      'format': formatVersion,
      'id': id,
      'startedAt': _startedAt!.toIso8601String(),
      'durationSec': elapsedSec,
      'samplingPeriodMs': samplingPeriod.inMilliseconds,
      'samples': {'acc': accCount, 'gyro': gyroCount},
      'device': await _deviceInfo(),
      'algo': {
        'version': RespirationEstimator.version,
        'config': estimator.cfg.toJson(),
        'liveMedianBpm': valid.isEmpty ? null : valid[valid.length ~/ 2],
        'counter': counter.toJson(),
        'tracker': {
          'version': RateTracker.version,
          'config': tracker.cfg.toJson(),
          'medianTrackedBpm':
              trackedVals.isEmpty ? null : trackedVals[trackedVals.length ~/ 2],
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
