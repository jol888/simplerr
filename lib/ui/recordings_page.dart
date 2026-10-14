import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../settings.dart';
import '../storage.dart';
import 'review_page.dart';

/// `20261013_204120` → `2026-10-13 20:41:20`.
String prettyId(String id) => id.length == 15
    ? '${id.substring(0, 4)}-${id.substring(4, 6)}-${id.substring(6, 8)} '
        '${id.substring(9, 11)}:${id.substring(11, 13)}:${id.substring(13, 15)}'
    : id;

class RecordingsPage extends StatefulWidget {
  final SettingsStore settings;

  const RecordingsPage({super.key, required this.settings});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  late Future<List<RecordingEntry>> _items = Storage.list();
  String _dir = '';

  @override
  void initState() {
    super.initState();
    Storage.dir().then((d) => setState(() => _dir = d.path));
  }

  void _reload() => setState(() => _items = Storage.list());

  Future<void> _share(List<RecordingEntry> items) async {
    final files = [
      for (final e in items) ...[
        XFile(e.csv.path, mimeType: 'text/csv'),
        if (e.meta.existsSync())
          XFile(e.meta.path, mimeType: 'application/json'),
      ]
    ];
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files));
  }

  Future<void> _delete(RecordingEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 rec_${e.id}？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await Storage.delete(e);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<RecordingEntry>>(
      future: _items,
      builder: (context, snap) {
        final items = snap.data ?? [];
        return Scaffold(
          appBar: AppBar(
            title: Text('历史记录（${items.length}）'),
            actions: [
              IconButton(
                icon: const Icon(Icons.share),
                tooltip: '导出全部',
                onPressed: items.isEmpty ? null : () => _share(items),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: SelectableText('adb pull $_dir',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final e = items[i];
                    final m = e.data;
                    final algo = m?.json['algo'] as Map?;
                    final bpm = (algo?['tracker']?['medianTrackedBpm'] ??
                        algo?['liveMedianBpm']) as num?;
                    final total = algo?['counter']?['total'] as num?;
                    final parts = [
                      if (m != null) '${m.durationSec.toStringAsFixed(0)} s',
                      if (bpm != null) '${bpm.toStringAsFixed(1)} 次/分',
                      if (total != null) '累计 $total',
                      if (m?.manualCount != null) '手数 ${m!.manualCount}',
                      if (m != null && m.posture.isNotEmpty) m.posture,
                      '${(e.bytes / 1024).toStringAsFixed(0)} KB',
                    ];
                    return ListTile(
                      title: Text(prettyId(e.id)),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ReviewPage(
                                entry: e, settings: widget.settings)));
                        _reload();
                      },
                      subtitle: Text(parts.join(' · ')),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                              icon: const Icon(Icons.share),
                              onPressed: () => _share([e])),
                          IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(e)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
