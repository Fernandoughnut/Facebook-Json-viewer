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

class InsightsTab extends StatelessWidget {
  final Store store;
  const InsightsTab({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final msgs = <Msg>[
          for (final c in store.chats.values)
            for (final m in c.messages) m,
        ];
        if (msgs.isEmpty) {
          return const Center(child: Text('Open a JSON file to see insights.'));
        }

        final bySender = <String, int>{};
        final byYear = <int, int>{};
        final byMonth = <String, int>{};
        final emojis = <String, int>{};
        var reactions = 0, media = 0, links = 0, replies = 0;
        for (final m in msgs) {
          final name = displayName(m.sender);
          bySender[name] = (bySender[name] ?? 0) + 1;
          if (m.t != null) {
            final d = DateTime.fromMillisecondsSinceEpoch(m.t!);
            byYear[d.year] = (byYear[d.year] ?? 0) + 1;
            final month = '${d.year}-${two(d.month)}';
            byMonth[month] = (byMonth[month] ?? 0) + 1;
          }
          media += m.media.length;
          if (m.share.isNotEmpty) links++;
          if (m.reply != null) replies++;
          for (final r in m.reactions) {
            reactions++;
            emojis[r.emoji] = (emojis[r.emoji] ?? 0) + 1;
          }
        }
        // Conversation-level analysis: response times, quiet gaps and vocabulary.
        final responses = <int>[];
        final gaps = <({int ms, String chat, int? t})>[];
        final wordsBySender = <String, Map<String, int>>{};
        final wordRe = RegExp(r"[a-z']{3,}", caseSensitive: false);
        for (final c in store.chats.values) {
          var longest = (ms: 0, chat: c.title, t: null as int?);
          for (var i = 1; i < c.messages.length; i++) {
            final a = c.messages[i - 1];
            final b = c.messages[i];
            if (a.t == null || b.t == null) continue;
            final gap = (b.t! - a.t!).abs();
            if (gap > longest.ms) longest = (ms: gap, chat: c.title, t: b.t);
            if (a.sender != b.sender) responses.add(gap);
          }
          if (longest.ms > 0) gaps.add(longest);
          for (final m in c.messages) {
            final name = displayName(m.sender);
            final counts = wordsBySender.putIfAbsent(
              name,
              () => <String, int>{},
            );
            for (final match in wordRe.allMatches(m.text.toLowerCase())) {
              final w = match.group(0)!;
              counts[w] = (counts[w] ?? 0) + 1;
            }
          }
        }
        gaps.sort((a, b) => b.ms.compareTo(a.ms));
        responses.sort();
        final medianResponse = responses.isEmpty
            ? 0
            : responses[responses.length ~/ 2];

        final topSenders = bySender.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final topEmojis = emojis.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final years = byYear.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        final months = byMonth.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        final maxSender = topSenders.isEmpty ? 1 : topSenders.first.value;
        final maxYear = years.isEmpty
            ? 1
            : years.map((e) => e.value).reduce((a, b) => a > b ? a : b);

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
                    Text('${msgs.length} messages'),
                    Text('${store.chats.length} conversations'),
                    Text('$reactions reactions'),
                    Text('$media media files'),
                    Text('$links links'),
                    Text('$replies replies'),
                    Text('${store.bookmarked().length} bookmarks'),
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
              'Messages per month',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final e in months.take(60))
              ListTile(dense: true, title: Text('${e.key}: ${e.value}')),
            Text(
              'Conversation rhythm',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            ListTile(
              dense: true,
              title: const Text('Typical reply time'),
              subtitle: Text(
                responses.isEmpty
                    ? 'Not enough data'
                    : '${Duration(milliseconds: medianResponse).inMinutes} min (median of ${responses.length} turns)',
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

class LinksTab extends StatelessWidget {
  final Store store;
  const LinksTab({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final links = <({Chat chat, Msg msg})>[];
        for (final c in store.chats.values) {
          for (final m in c.messages) {
            if (m.share.isNotEmpty) links.add((chat: c, msg: m));
          }
        }
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
    final dest = await pickFolder(store);
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
                      for (final name in x.s.missingSample) {
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
                itemCount: groups.length,
                itemBuilder: (context, i) {
                  final paths = groups.values.elementAt(i);
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
