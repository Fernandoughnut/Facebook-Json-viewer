// Extra tools: bookmarks and notes, conversation insights, links and media inventory.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'exporter.dart';
import 'models.dart';
import 'store.dart';
import 'util.dart';

/// Each job is [sourcePath, destinationPath]. Runs in an isolate: copying a
/// large photo library otherwise blocks the UI thread.
Future<int> _copyMediaFiles(List<List<String>> jobs) async {
  var copied = 0;
  for (final job in jobs) {
    try {
      await File(job[0]).copy(job[1]);
      copied++;
    } catch (_) {}
  }
  return copied;
}

class ToolsScreen extends StatelessWidget {
  final Store store;
  const ToolsScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tools'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.bookmark), text: 'Saved'),
              Tab(icon: Icon(Icons.insights), text: 'Insights'),
              Tab(icon: Icon(Icons.link), text: 'Links'),
              Tab(icon: Icon(Icons.photo_library), text: 'Media'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            BookmarksTab(store: store),
            InsightsTab(store: store),
            LinksTab(store: store),
            MediaTab(store: store),
          ],
        ),
      ),
    );
  }
}

class BookmarksTab extends StatelessWidget {
  final Store store;
  const BookmarksTab({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final hits = store.bookmarked();
        if (hits.isEmpty) {
          return const Center(
            child: Text(
              'No bookmarks yet. Tap the bookmark icon on a message.',
            ),
          );
        }
        return ListView.builder(
          itemCount: hits.length,
          itemBuilder: (context, i) {
            final h = hits[i];
            final m = h.msg;
            final note = store.noteFor(h.chat, m);
            return ListTile(
              title: Text(
                '${displayName(m.sender)}: ${m.text.isEmpty ? '[media]' : m.text}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${h.chat.title} · ${fmtDate(m.t)}${note.isEmpty ? '' : '\n📝 $note'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              isThreeLine: note.isNotEmpty,
              onTap: () => Navigator.of(context).pop(h),
              trailing: IconButton(
                tooltip: note.isEmpty ? 'Add a note' : 'Edit note',
                icon: const Icon(Icons.note_outlined),
                onPressed: () async {
                  final ctrl = TextEditingController(text: note);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Note'),
                      content: TextField(
                        controller: ctrl,
                        maxLines: 4,
                        autofocus: true,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true && context.mounted) {
                    store.setNote(h.chat, m, ctrl.text);
                  }
                  ctrl.dispose();
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _InsightsData {
  final int msgCount;
  final int chatCount;
  final int reactions;
  final int media;
  final int links;
  final int replies;
  final int maxSender;
  final int maxYear;
  final int medianResponse;
  final int responseCount;
  final List<MapEntry<String, int>> topSenders;
  final List<MapEntry<int, int>> years;
  final List<MapEntry<String, int>> months;
  final List<MapEntry<String, int>> topEmojis;
  final List<({int ms, String chat, int? t})> gaps;
  final Map<String, Map<String, int>> wordsBySender;

  const _InsightsData({
    required this.msgCount,
    required this.chatCount,
    required this.reactions,
    required this.media,
    required this.links,
    required this.replies,
    required this.maxSender,
    required this.maxYear,
    required this.medianResponse,
    required this.responseCount,
    required this.topSenders,
    required this.years,
    required this.months,
    required this.topEmojis,
    required this.gaps,
    required this.wordsBySender,
  });

  /// Rebuild the typed view from the isolate's sendable result.
  factory _InsightsData.fromResult(Map<String, Object?> r) {
    List<MapEntry<String, int>> stringCounts(Object? value) => [
      for (final e in value as List<dynamic>)
        MapEntry<String, int>('${e[0]}', e[1] as int),
    ];
    List<MapEntry<int, int>> yearCounts(Object? value) => [
      for (final e in value as List<dynamic>)
        MapEntry<int, int>(e[0] as int, e[1] as int),
    ];
    List<({int ms, String chat, int? t})> gapList(Object? value) => [
      for (final e in value as List<dynamic>)
        (ms: e[0] as int, chat: e[1] as String, t: e[2] as int?),
    ];

    final words = <String, Map<String, int>>{};
    for (final e in (r['wordsBySender'] as Map<String, dynamic>).entries) {
      words[e.key] = {
        for (final w in e.value as List<dynamic>) '${w[0]}': w[1] as int,
      };
    }

    return _InsightsData(
      msgCount: r['msgCount'] as int,
      chatCount: r['chatCount'] as int,
      reactions: r['reactions'] as int,
      media: r['media'] as int,
      links: r['links'] as int,
      replies: r['replies'] as int,
      maxSender: r['maxSender'] as int,
      maxYear: r['maxYear'] as int,
      medianResponse: r['medianResponse'] as int,
      responseCount: r['responseCount'] as int,
      topSenders: stringCounts(r['topSenders']),
      years: yearCounts(r['years']),
      months: stringCounts(r['months']),
      topEmojis: stringCounts(r['topEmojis']),
      gaps: gapList(r['gaps']),
      wordsBySender: words,
    );
  }
}

/// Flatten the store into sendable rows for the compute isolate. Aliases are
/// resolved here so the expensive pass does not need the global [gSettings].
Map<String, Object?> _insightsSnapshot(Store store) {
  final rows = <List<Object?>>[];
  for (final c in store.chats.values) {
    for (final m in c.messages) {
      rows.add([
        c.key,
        c.title,
        displayName(m.sender),
        m.t,
        m.text,
        m.media.length,
        m.share.isNotEmpty ? 1 : 0,
        m.reply != null ? 1 : 0,
        [for (final r in m.reactions) r.emoji],
      ]);
    }
  }
  return {'rows': rows};
}

/// Heavy read-only pass. Runs in an isolate; only sendable data crosses over.
/// Row layout: key, title, sender, time, text, media count, link flag,
/// reply flag, reaction emojis.
Map<String, Object?> analyzeInsightsRows(Map<String, Object?> input) {
  final rawRows = input['rows'] as List<dynamic>;

  final bySender = <String, int>{};
  final byYear = <int, int>{};
  final byMonth = <String, int>{};
  final emojis = <String, int>{};
  final responses = <int>[];
  final gapRows = <List<Object?>>[];
  final wordsBySender = <String, Map<String, int>>{};
  final chatKeys = <String>{};
  final wordRe = RegExp(r"[a-z']{3,}", caseSensitive: false);

  var msgCount = 0, reactions = 0, media = 0, links = 0, replies = 0;
  String? currentKey;
  String currentTitle = '';
  int? prevT;
  String? prevSender;
  var longestMs = 0;
  int? longestT;

  void finishChat() {
    if (longestMs > 0) gapRows.add([longestMs, currentTitle, longestT]);
  }

  for (final item in rawRows) {
    final row = item as List<dynamic>;
    final key = row[0] as String;
    final title = row[1] as String;
    final sender = row[2] as String;
    final t = row[3] as int?;
    final text = row[4] as String;
    final mediaCount = row[5] as int;
    final hasLink = row[6] == 1;
    final hasReply = row[7] == 1;
    final messageEmojis = row[8] as List<dynamic>;

    if (currentKey != null && key != currentKey) finishChat();
    if (key != currentKey) {
      currentKey = key;
      currentTitle = title;
      prevT = null;
      prevSender = null;
      longestMs = 0;
      longestT = null;
    }
    chatKeys.add(key);

    msgCount++;
    bySender[sender] = (bySender[sender] ?? 0) + 1;
    if (t != null) {
      final d = DateTime.fromMillisecondsSinceEpoch(t);
      byYear[d.year] = (byYear[d.year] ?? 0) + 1;
      final month = '${d.year}-${two(d.month)}';
      byMonth[month] = (byMonth[month] ?? 0) + 1;
    }
    media += mediaCount;
    if (hasLink) links++;
    if (hasReply) replies++;
    for (final item in messageEmojis) {
      final emoji = item as String;
      reactions++;
      emojis[emoji] = (emojis[emoji] ?? 0) + 1;
    }

    if (prevT != null && t != null) {
      final gap = (t - prevT).abs();
      if (gap > longestMs) {
        longestMs = gap;
        longestT = t;
      }
      if (prevSender != sender) responses.add(gap);
    }
    prevT = t;
    prevSender = sender;

    final counts = wordsBySender.putIfAbsent(sender, () => <String, int>{});
    for (final match in wordRe.allMatches(text.toLowerCase())) {
      final w = match.group(0)!;
      counts[w] = (counts[w] ?? 0) + 1;
    }
  }
  if (currentKey != null) finishChat();

  gapRows.sort((a, b) => (b[0] as int).compareTo(a[0] as int));
  responses.sort();
  final topSenders = bySender.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final topEmojis = emojis.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final years = byYear.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  final months = byMonth.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));

  final words = <String, List<List<Object?>>>{};
  for (final e in wordsBySender.entries) {
    words[e.key] = [
      for (final w in e.value.entries) [w.key, w.value],
    ];
  }

  return {
    'msgCount': msgCount,
    'chatCount': chatKeys.length,
    'reactions': reactions,
    'media': media,
    'links': links,
    'replies': replies,
    'maxSender': topSenders.isEmpty ? 1 : topSenders.first.value,
    'maxYear': years.isEmpty
        ? 1
        : years.map((e) => e.value).reduce((a, b) => a > b ? a : b),
    'medianResponse': responses.isEmpty ? 0 : responses[responses.length ~/ 2],
    'responseCount': responses.length,
    'topSenders': [
      for (final e in topSenders) [e.key, e.value],
    ],
    'years': [
      for (final e in years) [e.key, e.value],
    ],
    'months': [
      for (final e in months) [e.key, e.value],
    ],
    'topEmojis': [
      for (final e in topEmojis) [e.key, e.value],
    ],
    'gaps': gapRows,
    'wordsBySender': words,
  };
}

class InsightsTab extends StatefulWidget {
  final Store store;
  const InsightsTab({super.key, required this.store});

  @override
  State<InsightsTab> createState() => _InsightsTabState();
}

class _InsightsTabState extends State<InsightsTab> {
  Future<_InsightsData>? _future;
  String _sig = '';
  int _bookmarkRevision = 0;
  int _bookmarkCount = 0;

  int _countBookmarks() => widget.store.bookmarked().length;

  @override
  void initState() {
    super.initState();
    _bookmarkRevision = widget.store.bookmarkRevision;
    _bookmarkCount = _countBookmarks();
    widget.store.addListener(_onStoreChanged);
    gSettings?.addListener(_onSettingsChanged);
    _ensureFuture();
  }

  @override
  void didUpdateWidget(covariant InsightsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
      _sig = '';
      _future = null;
      _bookmarkRevision = widget.store.bookmarkRevision;
      _bookmarkCount = _countBookmarks();
      _ensureFuture();
      return;
    }
    final sig = _signature();
    if (sig != _sig || _future == null) {
      _bookmarkCount = _countBookmarks();
      _startAnalysis(sig);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    gSettings?.removeListener(_onSettingsChanged);
    super.dispose();
  }

  String _signature() =>
      '${identityHashCode(widget.store)}|${widget.store.dataRevision}'
      '|${gSettings?.revision ?? 0}';

  void _startAnalysis(String sig) {
    _sig = sig;
    final count = widget.store.chats.values.fold<int>(
      0,
      (n, c) => n + c.messages.length,
    );
    gSettings?.logBreadcrumb(
      'Insights analysis started ($count messages, '
      'keepRaw=${widget.store.settings.keepRaw})',
    );
    _future = compute(analyzeInsightsRows, _insightsSnapshot(widget.store))
        .then((r) {
          gSettings?.logBreadcrumb('Insights analysis finished');
          return _InsightsData.fromResult(r);
        });
  }

  void _ensureFuture() {
    final sig = _signature();
    if (sig == _sig && _future != null) return;
    _startAnalysis(sig);
  }

  void _onStoreChanged() {
    if (!mounted) return;
    final sig = _signature();
    final bookmarkRevision = widget.store.bookmarkRevision;
    if (sig == _sig &&
        bookmarkRevision == _bookmarkRevision &&
        _future != null) {
      return;
    }
    setState(() {
      _bookmarkRevision = widget.store.bookmarkRevision;
      _bookmarkCount = _countBookmarks();
      if (sig != _sig || _future == null) _startAnalysis(sig);
    });
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    final sig = _signature();
    if (sig == _sig && _future != null) return;
    setState(() {
      _bookmarkCount = _countBookmarks();
      if (sig != _sig || _future == null) _startAnalysis(sig);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_InsightsData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
        if (data.msgCount == 0) {
          return const Center(child: Text('Open a JSON file to see insights.'));
        }

        final reactions = data.reactions;
        final media = data.media;
        final links = data.links;
        final replies = data.replies;
        final medianResponse = data.medianResponse;
        final responseCount = data.responseCount;
        final gaps = data.gaps;
        final wordsBySender = data.wordsBySender;
        final topSenders = data.topSenders;
        final years = data.years;
        final months = data.months;
        final topEmojis = data.topEmojis;
        final maxSender = data.maxSender;
        final maxYear = data.maxYear;

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    Text('${data.msgCount} messages'),
                    Text('${data.chatCount} conversations'),
                    Text('$reactions reactions'),
                    Text('$media media files'),
                    Text('$links links'),
                    Text('$replies replies'),
                    Text('$_bookmarkCount bookmarks'),
                  ],
                ),
              ),
            ),
            Text(
              'Messages per person',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final e in topSenders)
              ListTile(
                dense: true,
                title: Text('${e.key}: ${e.value}'),
                subtitle: LinearProgressIndicator(value: e.value / maxSender),
              ),
            Text(
              'Messages per year',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final e in years)
              ListTile(
                dense: true,
                title: Text('${e.key}: ${e.value}'),
                subtitle: LinearProgressIndicator(value: e.value / maxYear),
              ),
            Text(
              'Messages per month (latest 60)',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final e in months.reversed.take(60))
              ListTile(dense: true, title: Text('${e.key}: ${e.value}')),
            Text(
              'Conversation rhythm',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            ListTile(
              dense: true,
              title: const Text('Typical reply time'),
              subtitle: Text(
                responseCount == 0
                    ? 'Not enough data'
                    : '${Duration(milliseconds: medianResponse).inMinutes} min (median of $responseCount turns)',
              ),
            ),
            for (final g in gaps.take(5))
              ListTile(
                dense: true,
                title: Text(
                  'Quiet gap: ${Duration(milliseconds: g.ms).inHours} h in ${g.chat}',
                ),
                subtitle: Text(fmtDate(g.t)),
              ),
            Text(
              'Most-used words by person',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final e in wordsBySender.entries)
              ListTile(
                dense: true,
                title: Text(e.key),
                subtitle: Text(
                  (e.value.entries.toList()
                        ..sort((a, b) => b.value.compareTo(a.value)))
                      .take(12)
                      .map((x) => '${x.key} (${x.value})')
                      .join(' · '),
                  maxLines: 3,
                ),
              ),
            if (topEmojis.isNotEmpty)
              Text(
                'Top reactions',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            for (final e in topEmojis.take(12))
              ListTile(dense: true, title: Text('${e.key}  ×${e.value}')),
          ],
        );
      },
    );
  }
}

class LinksTab extends StatefulWidget {
  final Store store;
  const LinksTab({super.key, required this.store});

  @override
  State<LinksTab> createState() => _LinksTabState();
}

class _LinksTabState extends State<LinksTab> {
  final List<({Chat chat, Msg msg})> _links = [];
  int _dataRevision = -1;

  void _refresh() {
    if (_dataRevision == widget.store.dataRevision) return;
    _dataRevision = widget.store.dataRevision;
    _links.clear();
    for (final c in widget.store.chats.values) {
      for (final m in c.messages) {
        if (m.share.isNotEmpty) _links.add((chat: c, msg: m));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        _refresh();
        final links = _links;
        if (links.isEmpty) {
          return const Center(child: Text('No shared links found.'));
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Export links (CSV)'),
                  onPressed: () async {
                    final csv = StringBuffer('chat,sender,date,url,context\n');
                    for (final l in links) {
                      final row = [
                        l.chat.title,
                        displayName(l.msg.sender),
                        fmtDate(l.msg.t),
                        l.msg.share,
                        l.msg.text.replaceAll('\n', ' '),
                      ].map((v) => '"${v.replaceAll('"', '""')}"').join(',');
                      csv.writeln(row);
                    }
                    final ok = await saveExport(
                      'links_${fmtDate(DateTime.now().millisecondsSinceEpoch)}.csv',
                      csv.toString(),
                      mimeType: 'text/csv',
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'Links exported.'
                                : 'Export cancelled or failed.',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: links.length,
                itemBuilder: (context, i) {
                  final l = links[i];
                  return ListTile(
                    title: Text(
                      l.msg.share,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${l.chat.title} · ${displayName(l.msg.sender)} · ${fmtDate(l.msg.t)}',
                    ),
                    onTap: () => openExternal(l.msg.share, context),
                    trailing: IconButton(
                      tooltip: 'Copy link',
                      icon: const Icon(Icons.copy),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: l.msg.share)),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class MediaTab extends StatelessWidget {
  final Store store;
  const MediaTab({super.key, required this.store});

  /// Copy found media into a folder with readable names. Originals are never moved,
  /// and the copying itself runs in an isolate.
  Future<void> copyWithReadableNames(BuildContext context) async {
    final dest = await pickFolder(
      store,
      navigator: Navigator.of(context, rootNavigator: true),
    );
    if (dest == null || !context.mounted) return;
    final sep = Platform.pathSeparator;
    final baseDir = dest.endsWith(sep)
        ? dest.substring(0, dest.length - 1)
        : dest;
    final jobs = <List<String>>[];
    final used = <String>{};
    for (final c in store.chats.values) {
      for (final m in c.messages) {
        for (final x in m.media) {
          final path = store.findMedia(x.uri, c);
          if (path == null) continue;
          final base =
              '${fmtDate(m.t)}_${safeFileName(displayName(m.sender))}_${safeFileName(x.name)}';
          var name = base;
          var n = 1;
          while (used.contains(name) ||
              File('$baseDir$sep$name').existsSync()) {
            final dot = base.lastIndexOf('.');
            final stem = dot > 0 ? base.substring(0, dot) : base;
            final ext = dot > 0 ? base.substring(dot) : '';
            name = '${stem}_${n++}$ext';
          }
          used.add(name);
          jobs.add([path, '$baseDir$sep$name']);
        }
      }
    }
    if (jobs.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No media files were found in the opened folders.'),
          ),
        );
      }
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _CopyMediaDialog(dest: baseDir, jobs: jobs),
    );
  }

  Future<void> showDuplicates(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _DuplicateDialog(store: store),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (store.chats.isEmpty) {
          return const Center(child: Text('Open a JSON file to see media.'));
        }
        final stats = [
          for (final c in store.chats.values) (chat: c, s: store.statsFor(c)),
        ];
        final total = stats.fold<int>(0, (n, x) => n + x.s.total);
        final missing = stats.fold<int>(0, (n, x) => n + x.s.missing);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('$total media references · $missing missing'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.content_copy),
                  label: const Text('Find duplicate files'),
                  onPressed: () => showDuplicates(context),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.drive_file_rename_outline),
                  label: const Text('Copy media with readable names'),
                  onPressed: () => copyWithReadableNames(context),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Export missing files (CSV)'),
                  onPressed: () async {
                    final b = StringBuffer('conversation,file\n');
                    for (final x in stats) {
                      for (final name in store.missingMediaNames(x.chat)) {
                        final row = [
                          x.chat.title,
                          name,
                        ].map((v) => '"${v.replaceAll('"', '""')}"').join(',');
                        b.writeln(row);
                      }
                    }
                    final ok = await saveExport(
                      'missing_media_${fmtDate(DateTime.now().millisecondsSinceEpoch)}.csv',
                      b.toString(),
                      mimeType: 'text/csv',
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'Missing media list exported.'
                                : 'Export cancelled or failed.',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final x in stats)
                    ExpansionTile(
                      title: Text(
                        x.chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${x.s.total} referenced · ${x.s.fromChat} in chat folders · '
                        '${x.s.fromShared} shared · ${x.s.missing} missing',
                      ),
                      children: [
                        for (final n in x.s.missingSample)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(n),
                          ),
                        if (x.s.missing > x.s.missingSample.length)
                          Text(
                            '… and ${x.s.missing - x.s.missingSample.length} more',
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DuplicateDialog extends StatefulWidget {
  final Store store;
  const _DuplicateDialog({required this.store});

  @override
  State<_DuplicateDialog> createState() => _DuplicateDialogState();
}

class _DuplicateDialogState extends State<_DuplicateDialog> {
  Map<String, List<String>>? _groups;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.store
        .duplicateMedia()
        .then((g) {
          if (mounted) setState(() => _groups = g);
        })
        .catchError((e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    // Map.values.elementAt() is linear, which makes a scrolled list of many
    // duplicate groups quadratic. Materialize once per rebuild instead.
    final groupPaths = groups?.values.toList(growable: false);
    final dialogHeight = MediaQuery.of(context).size.height * 0.55;
    return AlertDialog(
      title: Text(
        groups == null
            ? 'Finding duplicate files'
            : '${groups.length} duplicate group${groups.length == 1 ? '' : 's'}',
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: dialogHeight,
        child: groups == null
            ? Center(
                child: _error == null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('Hashing media…'),
                        ],
                      )
                    : Text('Could not scan media: $_error'),
              )
            : groups.isEmpty
            ? const Center(child: Text('No identical files found.'))
            : ListView.builder(
                itemCount: groupPaths!.length,
                itemBuilder: (context, i) {
                  final paths = groupPaths[i];
                  return ExpansionTile(
                    title: Text('${paths.length} copies'),
                    subtitle: Text(
                      paths.first.split(RegExp(r'[\\/]')).last,
                      overflow: TextOverflow.ellipsis,
                    ),
                    children: [
                      for (final p in paths)
                        ListTile(
                          dense: true,
                          title: SelectableText(
                            p,
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => openExternal(p, context),
                        ),
                    ],
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _CopyMediaDialog extends StatefulWidget {
  final String dest;
  final List<List<String>> jobs;
  const _CopyMediaDialog({required this.dest, required this.jobs});

  @override
  State<_CopyMediaDialog> createState() => _CopyMediaDialogState();
}

class _CopyMediaDialogState extends State<_CopyMediaDialog> {
  int? _copied;
  String? _error;

  @override
  void initState() {
    super.initState();
    compute(_copyMediaFiles, widget.jobs)
        .then((n) {
          if (mounted) setState(() => _copied = n);
        })
        .catchError((e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  @override
  Widget build(BuildContext context) {
    final copied = _copied;
    return AlertDialog(
      title: Text(copied == null ? 'Copying media' : 'Copy finished'),
      content: SizedBox(
        width: double.maxFinite,
        child: copied == null
            ? Row(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Copying ${widget.jobs.length} file(s) to ${widget.dest}…',
                    ),
                  ),
                ],
              )
            : Text(
                _error == null
                    ? 'Copied $copied of ${widget.jobs.length} file(s) to ${widget.dest}.'
                    : 'Could not copy media: $_error',
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
