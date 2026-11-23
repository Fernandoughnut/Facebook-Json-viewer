// Messages Viewer: opens exported Facebook / Messenger JSON and shows it as chats.
// Linux first; the same code is meant to run on Android.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'models.dart';
import 'store.dart';

void main() => runApp(const ViewerApp());

class ViewerApp extends StatelessWidget {
  const ViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0B7CFF);
    return MaterialApp(
      title: 'Messages Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

// ---------- helpers ----------

String two(int n) => n.toString().padLeft(2, '0');

String fmtDate(int? t) {
  if (t == null) return 'Unknown date';
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

String fmtTime(int? t) {
  if (t == null) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(t);
  return '${two(d.hour)}:${two(d.minute)}';
}

bool sameDay(int? a, int? b) => fmtDate(a) == fmtDate(b);

bool isImagePath(String p) {
  final ext = p.split('.').last.toLowerCase();
  return const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext);
}

Future<void> openExternal(String path, BuildContext context) async {
  if (Platform.isLinux) {
    await Process.run('xdg-open', [path]);
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Opening video and audio on this platform comes in the next step.')),
    );
  }
}

/// Ask for a folder. Returns a normal path, or null if cancelled / not supported yet.
Future<String?> pickFolder(Store store) async {
  final uri = await FilePicker.pickDirectory();
  if (uri == null) return null;
  if (uri.scheme != 'file') {
    // On Android this is a content:// folder handle; real folder support is the next step.
    store.setStatus('This platform returned a folder handle ($uri). Android folder access is not built yet.');
    return null;
  }
  return uri.toFilePath();
}

/// Splits [text] into spans with every occurrence of [q] highlighted (case-insensitive).
List<InlineSpan> highlightSpans(String text, String q, TextStyle? base, Color hl) {
  if (q.isEmpty) return [TextSpan(text: text, style: base)];
  final lt = text.toLowerCase();
  final lq = q.toLowerCase();
  if (lt.length != text.length) return [TextSpan(text: text, style: base)]; // odd Unicode: skip highlighting
  final out = <InlineSpan>[];
  var pos = 0;
  while (true) {
    final i = lt.indexOf(lq, pos);
    if (i < 0) break;
    if (i > pos) out.add(TextSpan(text: text.substring(pos, i), style: base));
    out.add(TextSpan(
      text: text.substring(i, i + q.length),
      style: (base ?? const TextStyle()).copyWith(backgroundColor: hl, color: Colors.black),
    ));
    pos = i + q.length;
  }
  if (pos < text.length) out.add(TextSpan(text: text.substring(pos), style: base));
  return out;
}

/// A short piece of [text] around the first match, for the results list.
String snippet(String text, String q) {
  final i = text.toLowerCase().indexOf(q.toLowerCase());
  if (i < 0 || text.length <= 140) return text;
  final start = math.max(0, i - 40);
  final end = math.min(text.length, i + q.length + 90);
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
}

class Pic {
  final String path;
  final String caption;
  const Pic(this.path, this.caption);
}

// ---------- media info dialog ----------

Future<void> showMediaInfo(BuildContext context, Store store, Chat chat) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: store,
      builder: (ctx, _) {
        final st = store.statsFor(chat);

        Widget dirTile(MediaDir d, Chat? owner) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder),
              title: SelectableText(d.path),
              subtitle: Text('${d.count} files'),
              trailing: IconButton(
                tooltip: 'Remove this folder',
                icon: const Icon(Icons.close),
                onPressed: () => store.removeMediaDir(d, chat: owner),
              ),
            );

        Future<void> add(Chat? owner) async {
          final dir = await pickFolder(store);
          if (dir != null) await store.addMediaDir(dir, chat: owner);
        }

        final heading = Theme.of(ctx).textTheme.titleSmall;
        return AlertDialog(
          title: Text('Media: ${chat.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Photos, videos and files referenced by this conversation: ${st.total}'),
                  Text('Found: ${st.fromChat + st.fromShared} '
                      '(${st.fromChat} in this conversation\'s folders, ${st.fromShared} in shared folders)'),
                  Text('Missing: ${st.missing}'),
                  if (st.missing > 0)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Show missing file names'),
                      children: [
                        for (final n in st.missingSample)
                          Align(alignment: Alignment.centerLeft, child: SelectableText(n)),
                        if (st.missing > st.missingSample.length)
                          Text('… and ${st.missing - st.missingSample.length} more'),
                      ],
                    ),
                  const SizedBox(height: 16),
                  Text('Folders for this conversation only', style: heading),
                  if (chat.dirs.isEmpty) const Text('None yet.'),
                  for (final d in chat.dirs) dirTile(d, chat),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => add(chat),
                      icon: const Icon(Icons.create_new_folder),
                      label: const Text('Add folder for this conversation'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Shared folders (used by every conversation)', style: heading),
                  if (store.sharedDirs.isEmpty) const Text('None yet.'),
                  for (final d in store.sharedDirs) dirTile(d, null),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => add(null),
                      icon: const Icon(Icons.folder_shared),
                      label: const Text('Add shared folder'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Lookup order: this conversation\'s folders first, then the shared ones. '
                    'Files are matched by the file name written in the JSON.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        );
      },
    ),
  );
}

// ---------- home: conversation list + chat ----------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final store = Store();
  Chat? selected;
  String filter = '';

  @override
  void dispose() {
    store.dispose();
    super.dispose();
  }

  Future<void> pickJson() async {
    // file_picker 13+: static call, returns an empty list when cancelled.
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return;
    final paths = files.map((f) => f.path).whereType<String>().toList();
    await store.addJsonFiles(paths);
    if (selected == null && store.chats.length == 1) {
      setState(() => selected = store.chats.values.first);
    }
  }

  Future<void> pickSharedMedia() async {
    final dir = await pickFolder(store);
    if (dir != null) await store.addMediaDir(dir);
  }

  void openChat(Chat c, bool wide) {
    if (wide) {
      setState(() => selected = c);
    } else {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(c.title)),
          body: ChatView(store: store, chat: c),
        ),
      ));
    }
  }

  Widget sidebar(bool wide) {
    final q = filter.toLowerCase();
    final chats = store.sortedChats.where((c) => q.isEmpty || c.title.toLowerCase().contains(q)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(onPressed: pickJson, icon: const Icon(Icons.description), label: const Text('Open JSON')),
              Tooltip(
                message: 'A media folder used by every conversation. Per-conversation folders are in the chat\'s media info.',
                child: OutlinedButton.icon(
                  onPressed: pickSharedMedia,
                  icon: const Icon(Icons.folder_shared),
                  label: const Text('Shared media'),
                ),
              ),
              TextButton(
                onPressed: () {
                  setState(() => selected = null);
                  store.clear();
                },
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Filter conversations',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => filter = v),
          ),
        ),
        Expanded(
          child: chats.isEmpty
              ? const Center(child: Text('No conversations yet'))
              : ListView.builder(
                  itemCount: chats.length,
                  itemBuilder: (context, i) {
                    final c = chats[i];
                    return ListTile(
                      selected: wide && selected?.key == c.key,
                      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${c.messages.length} messages · ${fmtDate(c.lastT == 0 ? null : c.lastT)}'),
                      trailing: c.dirs.isEmpty ? null : const Icon(Icons.folder, size: 16),
                      onTap: () => openChat(c, wide),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(store.status, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 800;
          return Scaffold(
            appBar: wide ? null : AppBar(title: const Text('Messages Viewer')),
            body: SafeArea(
              child: wide
                  ? Row(
                      children: [
                        SizedBox(width: 340, child: sidebar(true)),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: selected == null
                              ? const Center(child: Text('Open a JSON file, then pick a conversation.'))
                              : ChatView(key: ValueKey(selected!.key), store: store, chat: selected!),
                        ),
                      ],
                    )
                  : sidebar(false),
            ),
          );
        },
      ),
    );
  }
}

// ---------- chat view ----------

class ChatView extends StatefulWidget {
  final Store store;
  final Chat chat;
  const ChatView({super.key, required this.store, required this.chat});

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final qc = TextEditingController();
  final scroll = ItemScrollController();
  String? sender;
  bool mediaOnly = false;
  bool gallery = false;

  /// Results panel mode (optional). Off: typing in the search box filters the chat in place.
  /// On: the chat stays complete, matches are listed in a panel, and clicking one jumps to it.
  bool panelMode = false;
  bool resultsOpen = false; // narrow screens only: panel replaces the chat while true

  List<Msg> view = []; // what the chat list shows (chronological)
  List<int> results = []; // indices into [view] that match the search (panel mode only)
  List<Pic> pics = [];
  int _picsFor = -1;
  int _msgCount = -1;
  int? highlight; // index into [view] of the message we just jumped to
  Timer? _hlTimer;
  bool _wide = false;

  String get query => qc.text.trim();

  @override
  void initState() {
    super.initState();
    recompute();
    _msgCount = widget.chat.messages.length;
  }

  @override
  void dispose() {
    _hlTimer?.cancel();
    qc.dispose();
    super.dispose();
  }

  void recompute() {
    final q = query.toLowerCase();
    bool matches(Msg m) => q.isNotEmpty && (m.text.toLowerCase().contains(q) || m.share.toLowerCase().contains(q));
    view = widget.chat.messages.where((m) {
      if (sender != null && m.sender != sender) return false;
      if (mediaOnly && m.media.isEmpty) return false;
      if (!panelMode && q.isNotEmpty && !matches(m)) return false;
      return true;
    }).toList();
    results = [];
    if (panelMode && q.isNotEmpty) {
      for (var i = 0; i < view.length; i++) {
        if (matches(view[i])) results.add(i);
      }
    }
    _picsFor = -1; // photos depend on the filter too
    highlight = null;
  }

  List<Pic> buildPics() {
    final out = <Pic>[];
    final Iterable<Msg> src = (panelMode && query.isNotEmpty) ? results.map((i) => view[i]) : view;
    for (final m in src) {
      for (final x in m.media) {
        final p = widget.store.findMedia(x.uri, widget.chat);
        if (p == null || !isImagePath(p)) continue;
        final cap = '${m.sender} · ${fmtDate(m.t)} ${fmtTime(m.t)}'
            '${m.text.isNotEmpty ? '\n${m.text}' : ''}\n${p.split(RegExp(r'[\\/]')).last}';
        out.add(Pic(p, cap));
      }
    }
    return out;
  }

  void openPager(int start) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PicPager(pics: pics, start: start)));
  }

  void openPicByPath(String path) {
    final i = pics.indexWhere((p) => p.path == path);
    if (i >= 0) openPager(i);
  }

  /// Scroll the full conversation to message [idx] (an index into [view]) and flash it.
  void jumpToMessage(int idx) {
    setState(() {
      gallery = false;
      if (!_wide) resultsOpen = false;
      highlight = idx;
    });
    _hlTimer?.cancel();
    _hlTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => highlight = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The list is reversed (newest at the bottom = index 0), so flip the index.
      if (scroll.isAttached) scroll.jumpTo(index: view.length - 1 - idx, alignment: 0.4);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.store;
    if (_msgCount != widget.chat.messages.length) {
      recompute(); // more JSON files were added to this chat
      _msgCount = widget.chat.messages.length;
    }
    if (_picsFor != s.mediaVersion) {
      pics = buildPics();
      _picsFor = s.mediaVersion;
    }
    final senders = widget.chat.participants.toList()..sort();

    return LayoutBuilder(builder: (context, box) {
      _wide = box.maxWidth >= 900;
      final panelVisible = panelMode && query.isNotEmpty;
      final panelSide = panelVisible && _wide;
      final panelFull = panelVisible && !_wide && resultsOpen;

      final Widget body = gallery ? galleryView() : (panelFull ? resultsPanel() : listView());

      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: qc,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search messages',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {
                      recompute();
                      if (panelMode) resultsOpen = true;
                    }),
                  ),
                ),
                IconButton(
                  tooltip: panelMode
                      ? 'Results panel is ON (click to filter the chat in place instead)'
                      : 'Results panel is OFF (click to list matches in a panel and jump to them)',
                  isSelected: panelMode,
                  icon: const Icon(Icons.manage_search_outlined),
                  selectedIcon: const Icon(Icons.manage_search),
                  onPressed: () => setState(() {
                    panelMode = !panelMode;
                    recompute();
                    resultsOpen = panelMode;
                  }),
                ),
                IconButton(
                  tooltip: gallery ? 'Chat view' : 'Gallery',
                  icon: Icon(gallery ? Icons.chat : Icons.photo_library),
                  onPressed: () => setState(() => gallery = !gallery),
                ),
                IconButton(
                  tooltip: 'Media info and folders',
                  icon: const Icon(Icons.perm_media),
                  onPressed: () => showMediaInfo(context, s, widget.chat),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                DropdownButton<String?>(
                  value: sender,
                  hint: const Text('Everyone'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Everyone')),
                    for (final n in senders) DropdownMenuItem<String?>(value: n, child: Text(n)),
                  ],
                  onChanged: (v) => setState(() {
                    sender = v;
                    recompute();
                  }),
                ),
                const SizedBox(width: 12),
                const Text('I am '),
                DropdownButton<String>(
                  value: senders.contains(s.me) ? s.me : '',
                  items: [
                    const DropdownMenuItem<String>(value: '', child: Text('(not set)')),
                    for (final n in senders) DropdownMenuItem<String>(value: n, child: Text(n)),
                  ],
                  onChanged: (v) => s.setMe(v ?? ''),
                ),
                const SizedBox(width: 12),
                FilterChip(
                  label: const Text('Media only'),
                  selected: mediaOnly,
                  onSelected: (v) => setState(() {
                    mediaOnly = v;
                    recompute();
                  }),
                ),
                const SizedBox(width: 12),
                if (panelVisible && !_wide && !resultsOpen)
                  ActionChip(
                    avatar: const Icon(Icons.list, size: 18),
                    label: Text('Show ${results.length} results'),
                    onPressed: () => setState(() => resultsOpen = true),
                  )
                else
                  Text(
                    panelVisible ? '${results.length} matches in ${view.length}' : '${view.length} shown',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: panelSide
                ? Row(
                    children: [
                      Expanded(child: body),
                      const VerticalDivider(width: 1),
                      SizedBox(width: 360, child: resultsPanel()),
                    ],
                  )
                : body,
          ),
        ],
      );
    });
  }

  Widget resultsPanel() {
    final q = query;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            '${results.length} result${results.length == 1 ? '' : 's'} for "$q"',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: results.isEmpty
              ? const Center(child: Text('No matches'))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, i) {
                    final idx = results[results.length - 1 - i]; // newest first
                    final m = view[idx];
                    return ListTile(
                      dense: true,
                      selected: highlight == idx,
                      title: Text.rich(
                        TextSpan(children: highlightSpans(snippet(m.text, q), q, null, Colors.amber)),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${m.sender} · ${fmtDate(m.t)} ${fmtTime(m.t)}'),
                      onTap: () => jumpToMessage(idx),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget listView() {
    if (view.isEmpty) return const Center(child: Text('No messages match.'));
    // reverse: true keeps the newest message at the bottom and opens the chat there.
    return ScrollablePositionedList.builder(
      itemScrollController: scroll,
      reverse: true,
      padding: const EdgeInsets.all(8),
      itemCount: view.length,
      itemBuilder: (context, i) {
        final idx = view.length - 1 - i;
        final m = view[idx];
        final prev = idx > 0 ? view[idx - 1] : null;
        final newDay = prev == null || !sameDay(prev.t, m.t);
        final showName = prev == null || prev.sender != m.sender || newDay;
        final mine = widget.store.me.isNotEmpty && m.sender == widget.store.me;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(child: Text(fmtDate(m.t), style: Theme.of(context).textTheme.bodySmall)),
              ),
            Bubble(
              m: m,
              mine: mine,
              showName: showName,
              store: widget.store,
              chat: widget.chat,
              query: query,
              highlighted: highlight == idx,
              onPic: openPicByPath,
            ),
          ],
        );
      },
    );
  }

  Widget galleryView() {
    if (pics.isEmpty) {
      return Center(
        child: Text(widget.store.hasMedia(widget.chat)
            ? 'No photos match the current filters.'
            : 'Open a media folder first (media info button above).'),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: pics.length,
      itemBuilder: (context, i) => GestureDetector(
        onTap: () => openPager(i),
        child: Image.file(
          File(pics[i].path),
          fit: BoxFit.cover,
          cacheWidth: 300, // decode small: keeps big galleries light on memory
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
        ),
      ),
    );
  }
}

// ---------- one message ----------

class Bubble extends StatelessWidget {
  final Msg m;
  final bool mine;
  final bool showName;
  final Store store;
  final Chat chat;
  final String query;
  final bool highlighted;
  final void Function(String path) onPic;
  const Bubble({
    super.key,
    required this.m,
    required this.mine,
    required this.showName,
    required this.store,
    required this.chat,
    required this.query,
    required this.highlighted,
    required this.onPic,
  });

  Widget mediaWidget(BuildContext context, Media x) {
    final label = x.kind.replaceAll('_', ' ');
    final p = store.findMedia(x.uri, chat);
    if (p == null) {
      final miss = store.hasMedia(chat) && x.uri.isNotEmpty ? ' (not found in media folders)' : '';
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('📎 $label${x.uri.isEmpty ? '' : ': ${x.name}'}$miss', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    if (isImagePath(p)) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: GestureDetector(
          onTap: () => onPic(p),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(p),
              width: 260,
              cacheWidth: 520,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Text('⚠ cannot show ${x.name}'),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ActionChip(
        avatar: const Icon(Icons.play_arrow, size: 18),
        label: Text('$label: ${x.name}', overflow: TextOverflow.ellipsis),
        onPressed: () => openExternal(p, context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = mine ? cs.primary : cs.surfaceContainerHighest;
    final fg = mine ? cs.onPrimary : cs.onSurface;
    final maxW = math.min(560.0, MediaQuery.of(context).size.width * 0.8);

    final content = <Widget>[];
    if (m.text.isNotEmpty) {
      final base = TextStyle(color: fg, fontStyle: m.unsent ? FontStyle.italic : FontStyle.normal);
      content.add(SelectableText.rich(TextSpan(children: highlightSpans(m.text, query, base, Colors.amber))));
    } else if (m.unsent) {
      content.add(Text('This message was unsent', style: TextStyle(color: fg, fontStyle: FontStyle.italic)));
    }
    for (final x in m.media) {
      content.add(mediaWidget(context, x));
    }
    if (m.share.isNotEmpty) {
      content.add(SelectableText('🔗 ${m.share}', style: TextStyle(color: fg)));
    }
    if (content.isEmpty) {
      content.add(Text('[${m.type.isEmpty ? 'empty message' : m.type}]', style: TextStyle(color: fg.withValues(alpha: 0.7))));
    }

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Column(
          crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (showName && !mine)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 1),
                child: Text(m.sender, style: Theme.of(context).textTheme.labelSmall),
              ),
            Container(
              constraints: BoxConstraints(maxWidth: maxW),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(16),
                border: highlighted ? Border.all(color: Colors.amber, width: 3) : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: content),
            ),
            if (m.reactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
                child: Text(
                  m.reactions.map((r) => r.actor.isEmpty ? r.emoji : '${r.emoji} ${r.actor}').join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 1, 8, 0),
              child: Text(fmtTime(m.t), style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- full-screen photo viewer ----------

class PicPager extends StatefulWidget {
  final List<Pic> pics;
  final int start;
  const PicPager({super.key, required this.pics, required this.start});

  @override
  State<PicPager> createState() => _PicPagerState();
}

class _PicPagerState extends State<PicPager> {
  late final PageController ctrl = PageController(initialPage: widget.start);
  late int index = widget.start;

  @override
  void dispose() {
    ctrl.dispose();
    super.dispose();
  }

  void go(int delta) {
    ctrl.animateToPage(
      (index + delta).clamp(0, widget.pics.length - 1).toInt(),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => go(1),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text('${index + 1} / ${widget.pics.length}'),
          ),
          body: PageView.builder(
            controller: ctrl,
            itemCount: widget.pics.length,
            onPageChanged: (i) => setState(() => index = i),
            itemBuilder: (context, i) {
              final p = widget.pics[i];
              return Column(
                children: [
                  Expanded(
                    child: InteractiveViewer(
                      maxScale: 6,
                      child: Center(child: Image.file(File(p.path), fit: BoxFit.contain)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(p.caption, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
