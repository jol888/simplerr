import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'algo/rec_format.dart';

String recordingId(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}_'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

class RecordingEntry {
  final String id;
  final File csv;
  final File meta;
  final RecordingMeta? data;
  final int bytes;

  RecordingEntry(this.id, this.csv, this.meta, this.data, this.bytes);
}

/// Recordings live in the app's external files dir so they can be pulled with
/// `adb pull /sdcard/Android/data/dev.xhze.breath/files/recordings`.
class Storage {
  static Directory? _dir;

  static Future<Directory> dir() async {
    if (_dir != null) return _dir!;
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    _dir = Directory('${base.path}/recordings');
    await _dir!.create(recursive: true);
    return _dir!;
  }

  static Future<File> csvFile(String id) async =>
      File('${(await dir()).path}/rec_$id.csv');

  static Future<File> metaFile(String id) async =>
      File('${(await dir()).path}/rec_$id.json');

  static Future<List<RecordingEntry>> list() async {
    final d = await dir();
    final out = <RecordingEntry>[];
    await for (final f in d.list()) {
      final name = f.uri.pathSegments.last;
      if (f is! File || !name.startsWith('rec_') || !name.endsWith('.csv')) {
        continue;
      }
      final id = name.substring(4, name.length - 4);
      final meta = await metaFile(id);
      out.add(RecordingEntry(
          id, f, meta, await RecordingMeta.load(meta), await f.length()));
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  static Future<void> delete(RecordingEntry e) async {
    if (await e.csv.exists()) await e.csv.delete();
    if (await e.meta.exists()) await e.meta.delete();
  }
}
